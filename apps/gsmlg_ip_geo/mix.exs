defmodule GSMLG.IpGeo.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_ip_geo,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.IpGeo",
      description: "IP geolocation database using MMDB format (MaxMind/DB-IP)",
      package: package(),
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.IpGeo.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mmdb2_decoder, "~> 3.0"},
      {:http_fetch, "~> 0.8", runtime: false},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ~w(lib priv LICENSE mix.exs README.md),
      links: %{
        Changelog: "https://hexdocs.pm/gsmlg_ip_geo/changelog.html"
      }
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
