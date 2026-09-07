defmodule GSMLG.BrowserAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_browser_agent,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.BrowserAgent.Application, []},
      extra_applications: [:crypto, :logger]
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.20"},
      {:mint, "~> 1.9"},
      {:mint_web_socket, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:gsmlg_commander, in_umbrella: true},
      {:gsmlg_commander_protocol, in_umbrella: true}
    ]
  end
end
