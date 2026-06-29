defmodule GSMLG.Scout.Server.AgentRegistry do
  @moduledoc """
  In-memory registry of recent Scout Agent heartbeats.
  """

  use GenServer

  alias GSMLG.Scout.Settings

  @topic "gsmlg_scout:agents"
  @sweep_interval_ms 5_000
  @stale_heartbeat_multiplier 3

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
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call(:list, _from, state) do
    state = prune_stale(state)

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
    normalized = normalize(heartbeat, timestamp())
    state = Map.put(state, normalized.agent_id, normalized)
    broadcast(normalized)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    state = prune_stale(state)
    schedule_sweep()
    {:noreply, state}
  end

  defp normalize(heartbeat, received_at) do
    %{
      agent_id: heartbeat[:agent_id] || heartbeat["agent_id"],
      region: heartbeat[:region] || heartbeat["region"],
      status: heartbeat[:status] || heartbeat["status"],
      running_jobs: heartbeat[:running_jobs] || heartbeat["running_jobs"] || 0,
      capacity: heartbeat[:capacity] || heartbeat["capacity"] || 0,
      version: heartbeat[:version] || heartbeat["version"],
      timestamp: heartbeat[:timestamp] || heartbeat["timestamp"] || received_at,
      last_seen_at: received_at
    }
  end

  defp prune_stale(state) do
    now = DateTime.utc_now()
    ttl_ms = Settings.get()["agent"]["heartbeat_interval_ms"] * @stale_heartbeat_multiplier

    {stale, fresh} =
      Enum.split_with(state, fn {_agent_id, agent} -> stale?(agent, now, ttl_ms) end)

    Enum.each(stale, fn {_agent_id, agent} -> broadcast_removed(agent) end)

    Map.new(fresh)
  end

  defp stale?(agent, now, ttl_ms) do
    case DateTime.from_iso8601(agent.last_seen_at) do
      {:ok, last_seen_at, _offset} ->
        DateTime.diff(now, last_seen_at, :millisecond) > ttl_ms

      _ ->
        false
    end
  end

  defp broadcast(agent) do
    if Process.whereis(GSMLG.PubSub) do
      Phoenix.PubSub.broadcast(GSMLG.PubSub, @topic, {:agent_updated, agent})
    end
  end

  defp broadcast_removed(agent) do
    if Process.whereis(GSMLG.PubSub) do
      Phoenix.PubSub.broadcast(GSMLG.PubSub, @topic, {:agent_removed, agent})
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
