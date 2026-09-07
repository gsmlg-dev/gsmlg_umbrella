defmodule GSMLG.Browser.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_browser,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {GSMLG.Browser.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:gsmlg, in_umbrella: true},
      {:gsmlg_commander_protocol, in_umbrella: true},
      {:gsmlg_storage, in_umbrella: true},
      {:ecto_sql, "~> 3.0"},
      {:oban, "~> 2.18"}
    ]
  end
end
