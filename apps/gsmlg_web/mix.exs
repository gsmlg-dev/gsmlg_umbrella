defmodule GSMLGWeb.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14.1 or ~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {GSMLGWeb.Application, []},
      extra_applications: [:guardian, :logger, :runtime_tools]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.7"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_duskmoon, "~> 6.0"},
      {:bandit, "~> 1.0"},
      {:floki, "~> 0.32"},
      {:phoenix_live_dashboard, "~> 0.7"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:bun, "~> 1.4", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.18"},
      {:gsmlg, in_umbrella: true},
      {:gsmlg_component, in_umbrella: true},
      {:gsmlg_whois, in_umbrella: true},
      {:gsmlg_mac, in_umbrella: true},
      {:swoosh, "~> 1.3"},
      {:jason, "~> 1.2"},
      {:guardian, "~> 2.0"},
      {:guardian_phoenix, "~> 2.0"},
      {:guardian_db, "~> 3.0"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      {:absinthe, "~> 1.7.0"},
      {:absinthe_plug, "~> 1.5"},
      {:absinthe_phoenix, "~> 2.0"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.deploy": [
        "phx.digest.clean",
        "tailwind gsmlg_web --minify",
        "bun gsmlg_web --minify",
        "phx.digest"
      ]
    ]
  end
end
