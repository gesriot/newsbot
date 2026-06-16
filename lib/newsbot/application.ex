defmodule Newsbot.Application do
  @moduledoc """
  Application entrypoint. Starts the supervised Bot poller.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Newsbot.Bot
    ]

    opts = [strategy: :one_for_one, name: Newsbot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
