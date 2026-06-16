defmodule Newsbot.Digest do
  @moduledoc """
  RSS digest helpers.

  - feeds_for/1 : list of RSS URLs for a category (:apple | :it)
  - todays_articles/1 : today's items merged from the given feeds
  - get_article_summary(url, gemini_key) : fetches page, aggressively cleans ads/promo/other articles,
    then (if key present) asks Gemini Flash for a clean Russian summary.
  """

  require Logger

  # Gemini free-tier requests-per-minute budget for gemini-2.5-flash.
  # Pacing requests at >= 60s / RPM guarantees we never exceed it, regardless
  # of how many articles/feeds there are.
  @gemini_rpm 10

  # 429 retry policy (safety net for bursts or quota shared between sections).
  @max_retries 5
  @default_retry_ms 60_000
  # Don't block longer than this on a single 429 — a multi-minute retryDelay
  # usually means the daily quota (RPD) is exhausted, which waiting won't fix.
  @max_retry_wait_ms 120_000

  @feeds %{
    apple: [
      "https://www.iphones.ru/feed",
      "https://appleinsider.ru/feed"
    ],
    it: [
      "https://xakep.ru/feed/",
      "https://nuancesprog.ru/feed/"
    ]
  }

  @month_abbr %{
    1 => "Jan",
    2 => "Feb",
    3 => "Mar",
    4 => "Apr",
    5 => "May",
    6 => "Jun",
    7 => "Jul",
    8 => "Aug",
    9 => "Sep",
    10 => "Oct",
    11 => "Nov",
    12 => "Dec"
  }

  @doc "RSS feed URLs for a category, or [] for an unknown one."
  def feeds_for(category), do: Map.get(@feeds, category, [])

  @doc """
  Minimum delay (ms) to leave between consecutive Gemini requests so the
  free-tier RPM limit is never exceeded. Includes a 10% safety margin.
  """
  def gemini_pause_ms, do: round(60_000 / @gemini_rpm * 1.1)

  @doc """
  Today's articles merged from all given feeds, newest first.

  Each feed is fetched independently — a failing feed is skipped rather than
  failing the whole digest. Always returns {:ok, list}.
  """
  def todays_articles(feeds) when is_list(feeds) do
    articles =
      feeds
      |> Enum.flat_map(fn url ->
        case fetch_feed(url) do
          {:ok, xml} -> xml |> parse_rss_items() |> filter_today()
          {:error, _} -> []
        end
      end)
      |> Enum.sort_by(& &1.pubdate, :desc)

    {:ok, articles}
  end

  @doc """
  Main function used by the bot.

  Returns {:ok, %{title:, summary:, link:}}. `summary` always carries usable
  content: a Gemini summary when available, otherwise a cleaned excerpt of the
  article body — so an article is never dropped just because Gemini failed.

  Returns {:error, reason} only when the page itself cannot be fetched.
  """
  def get_article_summary(url, gemini_key \\ nil) do
    with {:ok, html} <- fetch_page(url) do
      {title, clean_text} = extract_main_clean_text(html)
      {:ok, %{title: title, summary: summarize(clean_text, gemini_key), link: url}}
    end
  end

  # --- internals ---

  defp fetch_feed(url) do
    case Req.get(url, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: b}} when is_binary(b) -> {:ok, b}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, e} -> {:error, e}
    end
  end

  defp fetch_page(url) do
    case Req.get(url, receive_timeout: 20_000, redirect: true) do
      {:ok, %{status: 200, body: html}} -> {:ok, html}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, e} -> {:error, e}
    end
  end

  defp parse_rss_items(xml) do
    case Floki.parse_document(xml) do
      {:ok, doc} ->
        doc
        |> Floki.find("item")
        |> Enum.map(fn item ->
          %{
            title: text(item, "title") || "(без заголовка)",
            link: text(item, "link") || "#",
            pubdate: text(item, "pubdate"),
            creator: text(item, "dc|creator") || text(item, "creator")
          }
        end)

      _ ->
        []
    end
  end

  defp text(node, sel) do
    case Floki.find(node, sel) do
      [] ->
        nil

      n ->
        Floki.text(n, sep: " ")
        |> String.trim()
        |> case do
          "" -> nil
          t -> t
        end
    end
  end

  # Month abbreviation -> number, derived from @month_abbr.
  @month_num for({n, abbr} <- @month_abbr, into: %{}, do: {String.downcase(abbr), n})

  defp filter_today(items) do
    today = Date.utc_today()

    Enum.filter(items, fn i -> parse_pubdate(i.pubdate) == {:ok, today} end)
  end

  # Parse the date out of an RFC-822 pubDate like "Tue, 16 Jun 2026 07:00:50 +0000".
  # NOTE: compared against today in UTC. Articles published late local-evening may
  # land on the previous UTC day; proper timezone handling would need :tzdata.
  defp parse_pubdate(pubdate) when is_binary(pubdate) do
    case Regex.run(~r/(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})/, pubdate) do
      [_, d, mon, y] ->
        with {day, _} <- Integer.parse(d),
             {year, _} <- Integer.parse(y),
             month when is_integer(month) <- Map.get(@month_num, String.downcase(mon)),
             {:ok, date} <- Date.new(year, month, day) do
          {:ok, date}
        else
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_pubdate(_), do: :error

  # === Strong ad / cross-promo cleaning ===

  defp extract_main_clean_text(html) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        title =
          Floki.find(doc, "h1")
          |> Floki.text(sep: " ")
          |> String.trim()
          |> case do
            "" -> "Статья"
            t -> t
          end

        # Remove big junk containers
        cleaned =
          doc
          |> Floki.filter_out("script,style,noscript,iframe,form,button")
          |> Floki.filter_out(
            "[class*='banner'],[class*='rekl'],[id*='ad'],.popular,.communities,.sidebar,.comments,#comments"
          )
          |> Floki.filter_out("[href*='damprodam'],[class*='trade']")

        # Take substantial paragraphs + headings that are not promo
        text =
          cleaned
          |> Floki.find("h2,h3,h4,p")
          |> Enum.map(&Floki.text(&1, sep: " "))
          # Collapse internal whitespace/newlines so multi-word junk markers match
          # (Floki keeps source line breaks, e.g. "Годовая\n подписка\n на\n Хакер").
          |> Enum.map(&normalize_ws/1)
          |> Enum.reject(&looks_like_junk?/1)
          |> Enum.uniq()
          |> Enum.join("\n\n")
          |> String.replace(~r/\n{3,}/, "\n\n")
          |> remove_common_leftover_phrases()
          |> String.trim()

        {title, text}

      _ ->
        {"Статья", ""}
    end
  end

  defp normalize_ws(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp looks_like_junk?(text) do
    t = String.downcase(text)

    short_promo =
      String.length(text) < 70 and String.contains?(t, ["http", "www.", "подробнее", "читать"])

    Enum.any?(
      [
        "что-то пошло не так",
        "рекомендуем",
        "похожие статьи",
        "читайте также",
        "будь первым",
        "оставь комментарий",
        "правила комментирования",
        "damprodam",
        "спонсор",
        "купить",
        "продать iphone",
        # промо-подписки и реклама магазинов/каналов
        "подпишись",
        "подписывайся",
        "подпишитесь",
        "подписывайтесь",
        "aliexpress",
        "по лучшим ценам",
        "в telegram и макс",
        "годовая подписка",
        # архив выпусков журнала «Хакер» в сайдбаре
        "хакер #",
        # подписи и источники картинок
        "изображение:",
        "фото:",
        # интерфейс сайта: регистрация / вход / cookie
        "новый пользователь",
        "регистрируясь",
        "условиями использования",
        "сбором куки",
        "добавьте фото профиля"
      ],
      &String.contains?(t, &1)
    ) or short_promo
  end

  defp remove_common_leftover_phrases(text) do
    text
    |> String.replace(~r/\b(Читайте также|Смотрите также|Похожие материалы)[^\n]*/i, "")
    |> String.replace(~r/^\s*[-–—]\s*.{0,100}$/m, "")
  end

  # === Gemini ===

  # Telegram messages cap at 4096 chars; keep summaries comfortably under it.
  @summary_limit 3500

  # Always returns a usable string. Gemini result when possible, else a cleaned
  # excerpt of the article — the article is delivered either way.
  defp summarize("", _key), do: ""
  defp summarize(text, nil), do: excerpt(text)
  defp summarize(text, _key) when byte_size(text) < 50, do: cap(text)

  defp summarize(text, key) do
    case call_gemini(text, key) do
      {:ok, summary} -> cap(summary)
      {:error, _reason} -> excerpt(text)
    end
  end

  defp excerpt(text) do
    text
    |> String.split(~r/\s+/, trim: true)
    |> Enum.join(" ")
    |> cap()
  end

  defp cap(text) do
    if String.length(text) > @summary_limit do
      String.slice(text, 0, @summary_limit) <> "…"
    else
      text
    end
  end

  defp call_gemini(text, api_key, attempt \\ 1) do
    url =
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=#{api_key}"

    prompt = """
    Сделай краткое, но информативное саммари этой технологической новости на русском языке (5-8 предложений).

    Исходный текст взят со страницы сайта и может содержать посторонние вставки из вёрстки. Суммируй ТОЛЬКО содержание самой новости и полностью игнорируй любой такой мусор, в том числе:
    - рекламу и призывы подписаться/перейти на каналы, промо товаров и магазинов (AliExpress, «по лучшим ценам», скидки, «подписывайтесь на каналы … в Telegram и МАКС» и т.п.);
    - интерфейс сайта: формы регистрации и входа, согласие с условиями использования и cookie, «добавьте фото профиля», кнопки, меню, блоки комментариев;
    - подписи к иллюстрациям и источники картинок («Изображение: …», «Фото: …»);
    - ссылки, URL и названия сайтов-источников; анонсы других материалов, «читайте также».

    Если фрагмент не относится к теме новости — не включай его в саммари ни в каком виде.

    Дополнительно:
    - Только важные факты, цифры и выводы.
    - Не повторяй одни и те же предложения и мысли.
    - Не вставляй ссылки и URL.
    - Начинай сразу с сути, без «В статье» или «Саммари статьи».
    - Нейтральный, но живой тон.

    Текст:
    #{text}
    """

    body = %{
      contents: [%{parts: [%{text: prompt}]}],
      generationConfig: %{
        temperature: 0.25,
        maxOutputTokens: 1024,
        # 2.5-flash — thinking-модель; отключаем размышления, иначе они
        # съедают бюджет maxOutputTokens и ответ приходит пустым
        thinkingConfig: %{thinkingBudget: 0}
      }
    }

    case Req.post(url, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: resp}} ->
        case get_in(resp, ["candidates", Access.at(0), "content", "parts", Access.at(0), "text"]) do
          # Empty 200 → treat as failure so the caller falls back to an excerpt
          # instead of sending a literal "no text" message to the user.
          nil -> {:error, :empty_gemini_response}
          s -> {:ok, String.trim(s)}
        end

      {:ok, %{status: 429, body: b}} ->
        cond do
          daily_quota_exhausted?(b) ->
            # Per-day quota is gone — waiting won't help; fall back immediately.
            Logger.error("Gemini: дневная квота исчерпана — fallback на выдержку")
            {:error, {:gemini, 429, b}}

          attempt <= @max_retries ->
            # Per-minute limit: wait out the window and retry (clamped).
            delay = min(retry_delay_ms(b), @max_retry_wait_ms)
            Logger.warning("Gemini 429 — ждём #{delay} мс (попытка #{attempt}/#{@max_retries})")
            Process.sleep(delay)
            call_gemini(text, api_key, attempt + 1)

          true ->
            {:error, {:gemini, 429, b}}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, {:gemini, s, b}}

      {:error, e} ->
        {:error, e}
    end
  end

  # True when a 429 body reports an exhausted per-day quota (vs per-minute).
  defp daily_quota_exhausted?(body) do
    (get_in(body, ["error", "details"]) || [])
    |> Enum.any?(fn d ->
      is_map(d) and String.contains?(to_string(d["@type"]), "QuotaFailure") and
        Enum.any?(d["violations"] || [], fn v ->
          is_map(v) and String.contains?(to_string(v["quotaId"]), "PerDay")
        end)
    end)
  end

  # Extract the server-suggested retry delay from a 429 body's RetryInfo,
  # in ms (with a small margin). Falls back to @default_retry_ms.
  defp retry_delay_ms(body) do
    details = get_in(body, ["error", "details"]) || []

    delay_str =
      Enum.find_value(details, fn d ->
        if is_map(d) and String.contains?(to_string(d["@type"]), "RetryInfo") do
          d["retryDelay"]
        end
      end)

    case delay_str && Float.parse(to_string(delay_str)) do
      {secs, _} -> trunc(secs * 1000) + 500
      _ -> @default_retry_ms
    end
  end
end
