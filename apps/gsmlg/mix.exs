defmodule GSMLG.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg,
      version: "5.13.9",
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
      {:phoenix_pubsub, "~> 2.4"},
      {:phoenix_session_process, "~> 1.0"},
      {:ecto_sql, "~> 3.14"},
      {:postgrex, "~> 0.22"},
      {:jason, "~> 1.4"},
      {:caddy, "~> 2.3"},
      {:swoosh, "~> 1.29"},
      {:tesla, "~> 1.22"},
      {:libcluster, "~> 3.5"},
      {:cachex, "~> 4.1"},
      {:concord, "~> 3.1"},
      {:gsmlg_config, in_umbrella: true},
      {:gsmlg_commander_protocol, in_umbrella: true},
      {:gsmlg_aws, in_umbrella: true},
      {:gsmlg_logger, in_umbrella: true},
      {:gsmlg_telemetry, in_umbrella: true},
      {:gsmlg_web_push, in_umbrella: true},
      {:ueberauth, "~> 0.11"},
      {:ueberauth_github, "~> 0.8"},
      {:styx, "~> 0.1"},
      {:mox, "~> 1.3", only: :test},
      {:meck, "~> 1.2", only: :test},
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
