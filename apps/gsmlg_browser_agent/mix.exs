defmodule GSMLG.BrowserAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_browser_agent,
      version: "5.13.10",
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
      {:http_fetch, "~> 0.21.16"},
      {:http_web_socket, "~> 0.21.16"},
      {:telemetry, "~> 1.4"},
      {:gsmlg_commander, in_umbrella: true},
      {:gsmlg_commander_protocol, in_umbrella: true}
    ]
  end
end
