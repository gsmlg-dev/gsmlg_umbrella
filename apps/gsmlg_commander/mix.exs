defmodule GSMLG.Commander.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_commander,
      version: "5.13.9",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto, :public_key, :ssl],
      mod: {GSMLG.Commander, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gsmlg_logger, in_umbrella: true},
      {:gsmlg_config, in_umbrella: true},
      {:gsmlg_commander_protocol, in_umbrella: true},
      {:phoenix_socket_client, "~> 0.8"},
      {:phoenix_pubsub, "~> 2.4"},
      {:jason, "~> 1.4"},
      {:erlexec, "~> 2.5"},
      {:bcrypt_elixir, "~> 3.3"},
      # Jido - Autonomous agent framework for Elixir
      # Used for building distributed, autonomous agents with dynamic workflows
      # Docs: https://hexdocs.pm/jido | GitHub: https://github.com/agentjido/jido
      {:jido, "~> 2.4"},
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
