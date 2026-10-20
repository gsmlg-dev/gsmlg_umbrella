defmodule Toml.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/gsmlg-dev/gsmlg_umbrella/tree/main/packages/gsmlg_toml"

  def project do
    [
      app: :gsmlg_toml,
      version: @version,
      elixir: "~> 1.14",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      description: "An implementation of TOML for Elixir projects",
      package: [
        files: ["lib", "mix.exs", "README.md", "LICENSE"],
        maintainers: ["Jonathan Gao"],
        licenses: ["Apache-2.0", "MIT"],
        links: %{"GitHub" => @source_url}
      ],
      deps: [{:jason, "~> 1.0", only: :test}]
    ]
  end

  def application, do: [extra_applications: []]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
