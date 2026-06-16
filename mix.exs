defmodule Newsbot.MixProject do
  use Mix.Project

  def project do
    [
      app: :newsbot,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Newsbot.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:floki, "~> 0.36"}
    ]
  end
end
