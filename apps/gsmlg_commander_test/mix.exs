defmodule GSMLG.CommanderTest.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :gsmlg_commander_test,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: "E2E Testing Framework for GSMLG Commander"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :inets, :ssl],
      mod: {GSMLG.CommanderTest.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # In-umbrella dependencies
      {:gsmlg_commander, in_umbrella: true},
      {:gsmlg_config, in_umbrella: true},

      # WebSocket client for test agents
      {:websockex, "~> 0.4"},

      # JSON encoding/decoding
      {:jason, "~> 1.4"},

      # PTY handling via erlexec
      {:erlexec, "~> 2.0"},

      # Development and test tools
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
