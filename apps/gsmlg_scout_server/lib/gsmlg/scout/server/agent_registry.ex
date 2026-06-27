defmodule GSMLG.Scout.Server.AgentRegistry do
  @moduledoc """
  In-memory registry of recent Scout Agent heartbeats.
  """

  use GenServer

  @topic "gsmlg_scout:agents"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  def update_heartbeat(heartbeat) when is_map(heartbeat) do
    GenServer.cast(__MODULE__, {:heartbeat, heartbeat})
  end

  def list_agents do
    GenServer.call(__MODULE__, :list)
  end

  if Mix.env() == :test do
    def reset do
      GenServer.call(__MODULE__, :reset)
    end
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:list, _from, state) do
    agents =
      state
      |> Map.values()
      |> Enum.sort_by(& &1.agent_id)

    {:reply, agents, state}
  end

  if Mix.env() == :test do
    def handle_call(:reset, _from, _state) do
      {:reply, :ok, %{}}
    end
  end

  @impl true
  def handle_cast({:heartbeat, heartbeat}, state) do
    normalized = normalize(heartbeat)
    state = Map.put(state, normalized.agent_id, normalized)
    broadcast(normalized)
    {:noreply, state}
  end

  defp normalize(heartbeat) do
    %{
      agent_id: heartbeat[:agent_id] || heartbeat["agent_id"],
      region: heartbeat[:region] || heartbeat["region"],
      status: heartbeat[:status] || heartbeat["status"],
      running_jobs: heartbeat[:running_jobs] || heartbeat["running_jobs"] || 0,
      capacity: heartbeat[:capacity] || heartbeat["capacity"] || 0,
      version: heartbeat[:version] || heartbeat["version"],
      timestamp: heartbeat[:timestamp] || heartbeat["timestamp"]
    }
  end

  defp broadcast(agent) do
    if Process.whereis(GSMLG.PubSub) do
      Phoenix.PubSub.broadcast(GSMLG.PubSub, @topic, {:agent_updated, agent})
    end
  end
end
