defmodule GSMLG.CommanderProtocol.MixProject do
  use Mix.Project

  def project do
    [
      app: :gsmlg_commander_protocol,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application, do: []
end
