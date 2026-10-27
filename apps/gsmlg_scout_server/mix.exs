defmodule GSMLG.ScoutServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_scout_server,
      version: "5.13.9",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.Scout.Server.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gsmlg, in_umbrella: true},
      {:gsmlg_scout, in_umbrella: true},
      {:phoenix_pubsub, "~> 2.4"}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"]
    ]
  end
end
