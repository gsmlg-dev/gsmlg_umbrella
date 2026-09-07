defmodule GSMLG.Browser.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: GSMLG.Browser.SessionRegistry},
      {DynamicSupervisor, strategy: :one_for_one, name: GSMLG.Browser.SessionSupervisor},
      GSMLG.Browser.EventConsumer,
      GSMLG.Browser.Scheduler
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Browser.Supervisor)
  end
end
