defmodule GSMLG.CommandPlatform.Supervisor do
  use Supervisor

  def start_link(name: name) do
    Supervisor.start_link(name, :ok)
  end

  @impl true
  def init(_) do
    children = [
      # Legacy commander agent
      {GSMLG.CommandPlatform.Agent, %{commanders: []}},
      # Main command platform GenServer
      {GSMLG.CommandPlatform, []},
      # PTY agent registry
      {GSMLG.CommandPlatform.AgentRegistry, []},
      # PTY session tracker
      {GSMLG.CommandPlatform.SessionTracker, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
