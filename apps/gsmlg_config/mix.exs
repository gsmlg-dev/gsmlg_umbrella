defmodule GSMLG.Config.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_config,
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

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {GSMLG.Config.Application, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gsmlg_logger, in_umbrella: true},
      {:gsmlg_telemetry, in_umbrella: true},
      {:nimble_options, "~> 1.0"}
    ]
  end
end
