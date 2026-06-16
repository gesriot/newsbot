defmodule Newsbot.Bot do
  @moduledoc """
  Minimal long-polling Telegram bot for news digests.

  Commands:
    /start — list available commands
    /apple — today's Apple news (iPhones.ru, AppleInsider.ru)
    /it    — today's IT news (Xakep, NUANCES PROG)

  Articles are pulled from RSS, cleaned of ads/promo, summarized via Gemini,
  and delivered one message per article (parse_mode: HTML).
  """
  use GenServer
  require Logger

  @api_base "https://api.telegram.org/bot"
  @poll_timeout 30
  @allowed_updates ["message"]

  # (no broad triggers anymore - only /start and /news)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(_state) do
    token =
      System.get_env("TELEGRAM_BOT_TOKEN") ||
        raise """
        TELEGRAM_BOT_TOKEN is not set.

        Run with:
            TELEGRAM_BOT_TOKEN=123456:ABC... mix run --no-halt
        """

    Logger.info("Newsbot starting (RSS digest mode)")

    state = %{
      token: token,
      offset: 0,
      # true while a digest is being delivered — prevents overlapping runs that
      # would share (and blow through) the Gemini rate limit
      busy: false
    }

    _ = delete_webhook(state)
    send(self(), :poll)

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state =
      case get_updates(state) do
        {:ok, updates, new_offset} when is_list(updates) ->
          # handle_update now returns the (possibly updated) state so we can thread rate-limit etc.
          final_state =
            Enum.reduce(updates, %{state | offset: new_offset}, fn upd, acc ->
              handle_update(upd, acc)
            end)

          final_state

        {:error, reason} ->
          Logger.warning("getUpdates error: #{inspect(reason)}")
          # small backoff on error to avoid tight loop on persistent failure
          Process.sleep(1000)
          state
      end

    # Schedule next poll immediately (the previous getUpdates already waited up to timeout)
    send(self(), :poll)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:digest_done, state) do
    {:noreply, %{state | busy: false}}
  end

  # --- Telegram API helpers ---

  defp api_url(state, method), do: @api_base <> state.token <> "/" <> method

  defp delete_webhook(state) do
    # Best effort; ignore errors (webhook may not be set)
    Req.post(api_url(state, "deleteWebhook"), json: %{drop_pending_updates: false})
  end

  defp get_updates(state) do
    body = %{
      offset: state.offset,
      limit: 10,
      timeout: @poll_timeout,
      allowed_updates: @allowed_updates
    }

    case Req.post(api_url(state, "getUpdates"),
           json: body,
           receive_timeout: (@poll_timeout + 5) * 1000
         ) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => updates}}} when is_list(updates) ->
        new_offset =
          case updates do
            [] -> state.offset
            _ -> (updates |> Enum.map(& &1["update_id"]) |> Enum.max()) + 1
          end

        {:ok, updates, new_offset}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http, status, body}}

      {:error, err} ->
        {:error, err}
    end
  end

  # Sends a message rendered as HTML (parse_mode: HTML). The `html` argument
  # must already be valid Telegram HTML (use html_escape/1 on dynamic text).
  defp send_html(state, chat_id, html) when is_binary(html) do
    body = %{
      chat_id: chat_id,
      text: html,
      parse_mode: "HTML",
      link_preview_options: %{is_disabled: true}
    }

    case Req.post(api_url(state, "sendMessage"), json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => msg}}} ->
        Logger.info(
          "Sent message (#{byte_size(html)} chars) to #{chat_id}, id=#{msg["message_id"]}"
        )

        :ok

      {:ok, %{status: status, body: body}} ->
        Logger.error("sendMessage(HTML) failed #{status}: #{inspect(body)}")
        {:error, {:http, status, body}}

      {:error, err} ->
        Logger.error("sendMessage(HTML) error: #{inspect(err)}")
        {:error, err}
    end
  end

  defp send_html(_state, _chat_id, _other), do: {:error, :invalid_html}

  # Escapes the characters Telegram requires inside HTML text content.
  defp html_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  # Escapes a URL for use inside an HTML attribute (adds &quot; on top of the
  # text escapes) and only accepts http/https — a malformed link returns nil so
  # the caller can drop the anchor rather than emit broken HTML.
  defp safe_href(url) when is_binary(url) do
    if String.starts_with?(url, ["http://", "https://"]) do
      url |> html_escape() |> String.replace("\"", "&quot;")
    else
      nil
    end
  end

  defp safe_href(_), do: nil

  defp send_text(state, chat_id, text) do
    body = %{chat_id: chat_id, text: text}

    case Req.post(api_url(state, "sendMessage"), json: body) do
      {:ok, %{status: 200, body: %{"ok" => true}}} -> :ok
      other -> Logger.warning("sendMessage non-200: #{inspect(other)}")
    end
  end

  # --- Update handling ---

  defp handle_update(%{"message" => msg} = _update, state) do
    chat = msg["chat"] || %{}
    chat_id = chat["id"]
    text = (msg["text"] || "") |> String.trim() |> String.downcase()
    from = msg["from"] || %{}
    username = from["username"] || from["first_name"] || "unknown"

    cond do
      is_nil(chat_id) ->
        state

      command?(text, "/start") or text == "start" ->
        Logger.info("/start from #{username} (chat #{chat_id})")
        send_help(state, chat_id)
        state

      command?(text, "/apple") ->
        Logger.info("/apple from #{username} (chat #{chat_id})")
        send_news(state, chat_id, :apple)

      command?(text, "/it") ->
        Logger.info("/it from #{username} (chat #{chat_id})")
        send_news(state, chat_id, :it)

      true ->
        state
    end
  end

  defp handle_update(_other, state), do: state

  # Matches "/cmd", "/cmd ..." and "/cmd@botname" (Telegram group form).
  defp command?(text, cmd) do
    text == cmd or String.starts_with?(text, cmd <> " ") or String.starts_with?(text, cmd <> "@")
  end

  defp send_help(state, chat_id) do
    send_text(
      state,
      chat_id,
      "Привет! Я присылаю саммари свежих статей за сегодня.\n\n" <>
        "Доступные команды:\n" <>
        "/apple — новости Apple (iPhones.ru, AppleInsider.ru)\n" <>
        "/it — новости IT (Xakep, NUANCES PROG)"
    )
  end

  defp send_news(%{busy: true} = state, chat_id, _category) do
    send_text(state, chat_id, "Идёт рассылка предыдущего раздела — дождись её окончания.")
    state
  end

  defp send_news(state, chat_id, category) do
    feeds = Newsbot.Digest.feeds_for(category)

    case Newsbot.Digest.todays_articles(feeds) do
      {:ok, []} ->
        send_text(state, chat_id, "Сегодня по этому разделу новых материалов нет.")
        state

      {:ok, articles} ->
        header_html =
          "<b>📰 #{category_title(category)} — саммари за сегодня (#{length(articles)} статей)</b>\n\n" <>
            "Каждая статья — отдельным сообщением."

        _ = send_html(state, chat_id, header_html)

        gemini_key = System.get_env("GEMINI_API_KEY")
        # Pace every article under the Gemini free-tier RPM limit (see Digest).
        pause = Newsbot.Digest.gemini_pause_ms()

        # Deliver in the background, one message per article. A crash on any one
        # article is contained (try/rescue in deliver_article) so the rest still
        # go out. The busy flag is always cleared via :digest_done.
        Task.start(fn ->
          try do
            articles
            |> Enum.with_index(1)
            |> Enum.each(fn {art, idx} ->
              deliver_article(state, chat_id, art, idx, gemini_key, pause)
            end)
          after
            GenServer.cast(__MODULE__, :digest_done)
          end
        end)

        %{state | busy: true}
    end
  end

  # Builds and sends exactly one article message. Never raises out — any failure
  # is logged so it can't take down the rest of the digest.
  defp deliver_article(state, chat_id, art, idx, gemini_key, pause) do
    try do
      html =
        case Newsbot.Digest.get_article_summary(art.link, gemini_key) do
          {:ok, %{title: title, summary: summary, link: link}} ->
            article_html(idx, title, summary, link)

          {:error, reason} ->
            # Page unreachable — still deliver the article using RSS title + link.
            Logger.warning("Page fetch failed for #{art.link}: #{inspect(reason)}")
            article_html(idx, art.title, "", art.link)
        end

      deliver_with_retry(state, chat_id, html, idx, 2)
    rescue
      e -> Logger.error("Article #{idx} (#{art.link}) crashed: #{Exception.message(e)}")
    end

    Process.sleep(pause)
  end

  # Sends one article, retrying transient Telegram failures so a single hiccup
  # doesn't silently drop the article.
  defp deliver_with_retry(state, chat_id, html, idx, attempts) do
    case send_html(state, chat_id, html) do
      :ok ->
        :ok

      {:error, _reason} when attempts > 1 ->
        Process.sleep(1_000)
        deliver_with_retry(state, chat_id, html, idx, attempts - 1)

      {:error, reason} ->
        Logger.error("Article #{idx} not delivered after retries: #{inspect(reason)}")
        :error
    end
  end

  # Numbered title, optional summary, clickable link at the end.
  defp article_html(idx, title, summary, link) do
    body = String.trim(summary || "")

    link_part =
      case safe_href(link) do
        nil -> []
        href -> ["<a href=\"#{href}\">Открыть оригинал</a>"]
      end

    parts =
      ["<b>#{idx}) #{html_escape(title)}</b>"] ++
        if(body == "", do: [], else: [html_escape(body)]) ++
        link_part

    Enum.join(parts, "\n\n")
  end

  defp category_title(:apple), do: "Apple"
  defp category_title(:it), do: "IT"
  defp category_title(_), do: "Новости"
end
