defmodule GSMLG.Component.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_component,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14.1 or ~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {GSMLG.ComponentServer, []},
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:phoenix_duskmoon, "~> 6.0"},
      {:phoenix_react_server, "~> 0.5"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.0"},
      {:gettext, "~> 0.18"}
    ]
  end
end
