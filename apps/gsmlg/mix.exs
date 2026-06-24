defmodule GSMLG.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      xref: [exclude: [GSMLG.Web.Endpoint]]
    ]
  end

  def application do
    [
      mod: {GSMLG.Application, []},
      extra_applications: [:logger, :runtime_tools, :os_mon]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix_pubsub, "~> 2.0"},
      {:phoenix_session_process, "~> 1.0"},
      {:ecto_sql, "~> 3.0"},
      {:postgrex, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      {:caddy, "~> 2.3"},
      {:swoosh, "~> 1.3"},
      {:tesla, "~> 1.11"},
      {:finch, "~> 0.19"},
      {:libcluster, "~> 3.5"},
      {:cachex, "~> 4.0"},
      {:gsmlg_config, in_umbrella: true},
      {:gsmlg_aws, in_umbrella: true},
      {:gsmlg_mnesia, in_umbrella: true},
      {:gsmlg_logger, in_umbrella: true},
      {:gsmlg_telemetry, in_umbrella: true},
      {:gsmlg_web_push, in_umbrella: true},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      {:oban, "~> 2.18"},
      {:mox, "~> 1.0", only: :test},
      {:meck, "~> 0.9 or ~> 1.0", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      setup: ["deps.get", "ecto.setup"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      # Database setup is handled at umbrella level in CI
      # For local development, run `mix ecto.create && mix ecto.migrate` first
      test: ["test"],
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
