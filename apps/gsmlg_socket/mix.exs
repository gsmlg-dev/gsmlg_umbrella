defmodule GSMLG.Socket.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_socket,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.Socket",
      description: "GSMLG specify Socket connection package",
      package: package(),
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :ssl, :logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.18", only: [:dev]}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
      # {:sibling_app_in_umbrella, in_umbrella: true}
    ]
  end

  defp package do
    [
      maintainers: ["Jonathan Gao"],
      licenses: ["MIT"],
      files: ~w(lib LICENSE mix.exs README.md),
      links: %{
        Changelog: "https://hexdocs.pm/gsmlg_socket/changelog.html"
      }
    ]
  end
end
