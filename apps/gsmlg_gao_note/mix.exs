defmodule GSMLG.GaoNote.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_gao_note,
      version: "5.13.9",
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
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gsmlg, in_umbrella: true},
      {:gsmlg_storage, in_umbrella: true},
      {:styx, "~> 0.1"},
      {:gaoxy_http, "~> 0.12", only: :test},
      {:plug, "~> 1.20"},
      # TODO(upstream): gsmlg-opt/backplane#120 still requires Finch/Mint transitively.
      {:backplane_mcp_protocol, "~> 1.10"},
      {:jason, "~> 1.4"},
      {:tesla, "~> 1.22"},
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
