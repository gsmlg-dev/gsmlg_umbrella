defmodule GSMLG.Storage.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_storage,
      version: "5.13.13",
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
      mod: {GSMLG.Storage.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gsmlg, in_umbrella: true},
      {:ex_storage_service_sdk, "~> 0.8"},
      {:vix, "~> 0.42"},
      {:gaoxy_http, "~> 0.12", only: :test},
      # Independent oracles for wire-level S3 signature and XML assertions.
      {:aws_signature, "~> 0.4", only: :test},
      {:sweet_xml, "~> 0.7", only: :test},
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
