defmodule GSMLG.Scout.Server.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        GSMLG.Scout.Server.AgentRegistry,
        GSMLG.Scout.Server.JobManager
      ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Scout.Server.Supervisor)
  end
end
