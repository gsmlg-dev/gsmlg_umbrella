defmodule GSMLG.PKI.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_pki,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :public_key, :logger, :ssl, :syntax_tools]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:gsmlg_couchdb, in_umbrella: true},
      {:gsmlg_telemetry, in_umbrella: true}
    ]
  end
end
