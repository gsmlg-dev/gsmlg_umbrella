defmodule GSMLG.Config.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Configuration is now loaded via runtime.exs before the application starts
    # No supervision tree needed - GSMLG.Config is now a pure module with no state
    # All configuration is stored in Application environment

    children = []

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Config.Supervisor)
  end
end
