defmodule GSMLG.Whois.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_whois,
      version: "5.13.8",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      elixirc_paths: elixirc_paths(Mix.env()),
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.Whois",
      description: "Whois lookup for Domain / IP / ASN",
      package: package(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:telemetry, "~> 1.4"},
      {:http_fetch, "~> 0.21"},
      {:postgrex, "~> 0.22", optional: true},
      {:concord, "~> 2.4", optional: true},
      # TODO(upstream): gsmlg-dev/concord#103 - retain the v2-compatible ExTurso API
      # while the umbrella's PTY controller PID migration is blocked.
      {:ex_turso, "~> 0.3", optional: true, runtime: false},
      {:ex_doc, "~> 0.40", runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ~w(lib LICENSE mix.exs README.md),
      links: %{
        Changelog: "https://hexdocs.pm/gsmlg_whois/changelog.html"
      }
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
