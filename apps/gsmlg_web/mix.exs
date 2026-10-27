defmodule GSMLG.Web.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_web,
      version: "5.13.8",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # TODO(upstream): duskmoon-dev/duskmoon-bundler#7 (umbrella reload ownership)
      compilers: Mix.compilers() ++ [:hologram],
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
      {:duskmoon_hologram, "~> 10.0.8"},
      {:phoenix_ecto, "~> 4.7"},
      {:phoenix_html, "~> 4.3"},
      {:phoenix_live_reload, "~> 1.7", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_duskmoon, "~> 10.0"},
      {:gaoxy_http, "~> 0.12"},
      {:websock_adapter, "~> 0.12", hex: :gaoxy_websock_adapter, override: true},
      {:floki, "~> 0.38"},
      {:mdex, "~> 0.14"},
      {:lazy_html, "~> 0.1"},
      {:phoenix_live_dashboard, "~> 0.9"},
      {:duskmoon_bundler_runtime, "~> 10.0.8"},
      {:duskmoon_bundler, "~> 10.0.8", runtime: Mix.env() == :dev},
      {:telemetry_metrics, "~> 1.2"},
      {:telemetry_poller, "~> 1.3"},
      {:gettext, "~> 1.0"},
      {:gsmlg, in_umbrella: true},
      {:proxy_rules, in_umbrella: true},
      {:gsmlg_component, in_umbrella: true},
      {:gsmlg_ip_geo, in_umbrella: true},
      {:gsmlg_whois, in_umbrella: true},
      {:gsmlg_mac, in_umbrella: true},
      {:gsmlg_web_push, in_umbrella: true},
      {:gsmlg_storage, in_umbrella: true},
      {:gsmlg_gao_note, in_umbrella: true},
      {:swoosh, "~> 1.29"},
      {:jason, "~> 1.4"},
      {:tesla, "~> 1.22"},
      {:guardian, "~> 2.5"},
      {:guardian_phoenix, "~> 2.0"},
      {:guardian_db, "~> 3.0"},
      {:open_api_spex, "~> 3.22"},
      {:ueberauth, "~> 0.11"},
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
      test: [&enable_hologram/1, "test"],
      "phx.server": [&enable_hologram/1, "phx.server"],
      "assets.setup": ["npm.install"],
      "assets.build": ["duskmoon_bundler.build gsmlg_web --tailwind --no-minify"],
      "assets.deploy": [
        "phx.digest.clean --no-compile",
        "duskmoon_bundler.build gsmlg_web --tailwind",
        "phx.digest --no-compile"
      ],
      lint: ["credo --strict", "dialyzer"]
    ]
  end

  defp enable_hologram(_args), do: System.put_env("HOLOGRAM_START", "1")
end
