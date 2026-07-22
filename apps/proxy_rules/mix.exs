defmodule GSMLG.ProxyRules.MixProject do
  use Mix.Project

  def project do
    [
      app: :proxy_rules,
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
      mod: {GSMLG.ProxyRules.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:finch, "~> 0.23"},
      {:file_system, "~> 1.1"},
      {:idna, "~> 7.1"},
      {:telemetry, "~> 1.3"},
      {:gsmlg_telemetry, in_umbrella: true},
      {:stream_data, "~> 1.3", only: [:dev, :test]},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end
end
