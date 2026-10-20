defmodule GSMLG.AWS.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_aws,
      version: "5.13.8",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description: "AWS S3, Route53 and DynamoDB helpers with caching and Finch transport",
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:aws, "~> 1.0"},
      {:cachex, "~> 4.0"},
      {:finch, "~> 0.19"},
      {:tesla, "~> 1.11"},
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
        GitHub: "https://github.com/gsmlg-dev/gsmlg_umbrella/tree/main/apps/gsmlg_aws"
      }
    ]
  end

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
