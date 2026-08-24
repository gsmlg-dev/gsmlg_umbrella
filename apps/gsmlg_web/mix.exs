defmodule GSMLG.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_web,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
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
      mod: {GSMLG.Web.Application, []},
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
      {:phoenix, "~> 1.8"},
      {:phoenix_ecto, "~> 4.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.6", only: :dev},
      {:phoenix_live_view, "~> 1.0"},
      {:phoenix_duskmoon, ">= 9.12.2 and < 10.0.0"},
      {:bandit, "~> 1.0"},
      {:floki, "~> 0.38"},
      {:lazy_html, "~> 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.7"},
      {:tailwind, "~> 0.2", runtime: Mix.env() == :dev},
      {:bun, "~> 2.0", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 0.18 or ~> 1.0"},
      {:gsmlg, in_umbrella: true},
      {:proxy_rules, in_umbrella: true},
      {:gsmlg_component, in_umbrella: true},
      {:gsmlg_ip_geo, in_umbrella: true},
      {:gsmlg_whois, in_umbrella: true},
      {:gsmlg_mac, in_umbrella: true},
      {:gsmlg_web_push, in_umbrella: true},
      {:gsmlg_storage, in_umbrella: true},
      {:gsmlg_gao_note, in_umbrella: true},
      {:swoosh, "~> 1.3"},
      {:jason, "~> 1.2"},
      {:guardian, "~> 2.0"},
      {:guardian_phoenix, "~> 2.0"},
      {:guardian_db, "~> 3.0"},
      {:open_api_spex, "~> 3.22"},
      {:ueberauth, "~> 0.10"},
      {:ueberauth_github, "~> 0.8"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get"],
      # Database setup is handled at umbrella level in CI
      # For local development, run `mix ecto.create && mix ecto.migrate` first
      test: ["test"],
      "assets.deploy": [
        "phx.digest.clean --no-compile",
        "tailwind gsmlg_web --minify",
        "bun gsmlg_web --minify",
        "phx.digest --no-compile"
      ],
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
