defmodule PhoenixClient.Mixfile do
  use Mix.Project

  def project do
    [
      app: :gsmlg_phoenix_client,
      version: "0.11.1",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      elixirc_paths: elixirc_paths(Mix.env()),
      lockfile: "../../mix.lock",
      elixir: "~> 1.14",
      build_embedded: Mix.env() == :prod,
      start_permanent: Mix.env() == :prod,
      description: description(),
      package: package(),
      docs: [extras: ["README.md"], main: "readme"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :ssl],
      mod: {PhoenixClient, []}
    ]
  end

  defp deps do
    [
      {:websocket_client, "~> 1.3"},
      {:jason, "~> 1.2", optional: true},
      {:phoenix, "~> 1.7", only: :test},
      {:plug_cowboy, "~> 2.0", only: :test},
      {:ex_doc, "~> 0.18", only: :dev}
    ]
  end

  defp description do
    """
    Connect to Phoenix Channels from Elixir
    """
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => "https://github.com/mobileoverlord/phoenix_client"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
end
