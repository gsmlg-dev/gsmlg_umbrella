defmodule GSMLG.Mnesia.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_mnesia,
      version: "0.1.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.13",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.Mnesia",
      description: ":mnesia database wrapper",
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:mnesia, :logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false},
      {:inch_ex, ">= 0.0.0", only: :docs}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ~w(lib priv LICENSE mix.exs README.md),
      links: %{
        Changelog: "https://hexdocs.pm/gsmlg_mnesia/changelog.html"
      }
    ]
  end

  # Compilation Paths
  defp elixirc_paths(:test), do: ["lib", "test/support", "test/support.ex"]
  defp elixirc_paths(:docs), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]
end
