defmodule GSMLG.Socket.MixProject do
  use Mix.Project

  @version "5.13.8"

  def project do
    [
      app: :gsmlg_socket,
      version: @version,
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      name: "GSMLG.Socket",
      description: "GSMLG specify Socket connection package",
      package: package(),
      aliases: aliases(),
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
      internal_dependency(:gsmlg_telemetry),
      {:ex_doc, "~> 0.18", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"},
    ]
  end

  defp internal_dependency(app) do
    # Hex excludes in_umbrella dependencies from package requirements.
    if System.get_env("GSMLG_HEX_BUILD") != "1" and
         Path.basename(Path.dirname(__DIR__)) == "apps" and
         File.regular?(Path.join([__DIR__, "..", Atom.to_string(app), "mix.exs"])) do
      {app, @version, in_umbrella: true}
    else
      {app, @version}
    end
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

  defp aliases do
    [
      lint: ["credo --strict", "dialyzer"]
    ]
  end
end
