defmodule GSMLG.WebPush.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_web_push,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
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

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:http_fetch, "~> 0.10"},
      {:jose, "~> 1.11"},
      {:jason, "~> 1.2"},
      {:phoenix, "~> 1.8"},
      {:earmark, "~> 1.0", only: :dev},
      {:ex_doc, "~> 0.11", only: :dev},
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
