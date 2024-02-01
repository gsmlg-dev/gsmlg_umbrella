defmodule GSMLGOpenAI.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_openai,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
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
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.0"},
      {:yaml_elixir, "~> 2.9"},
      {:mix_test_watch, "~> 1.0"},
      # {:exvcr, ">= 0.0.0", only: :test},
      {:mock, "~> 0.3.6", only: :test},
      {:ex_doc, ">= 0.19.2", only: :dev},
      {:dialyxir, "~> 1.2", only: [:dev], runtime: false},
      {:credo, "~> 1.6", only: [:dev, :test], runtime: false}
    ]
  end
end
