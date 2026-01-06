defmodule GSMLG.CommanderTest.Application do
  @moduledoc """
  Application module for Commander E2E Test Framework.

  This application manages the supervision tree for E2E testing components:
  - Registry for tracking test resources
  - DynamicSupervisor for test agents
  - AgentManager for managing agent lifecycle
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Registry for tracking test resources (agents, PTY sessions, etc.)
      {Registry, keys: :unique, name: GSMLG.CommanderTest.Registry},

      # DynamicSupervisor for test agent processes
      {DynamicSupervisor,
       name: GSMLG.CommanderTest.AgentSupervisor,
       strategy: :one_for_one,
       max_restarts: 0}
    ]

    opts = [strategy: :one_for_one, name: GSMLG.CommanderTest.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
