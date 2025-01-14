defmodule GSMLG.Whois.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_whois,
      version: "0.4.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      elixirc_paths: elixirc_paths(Mix.env()),
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.Whois",
      description: "Whois lookup for Domain / IP / ASN",
      package: package(),
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
        {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
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
end
