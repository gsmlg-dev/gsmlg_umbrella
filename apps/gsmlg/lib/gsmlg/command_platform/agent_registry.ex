defmodule GSMLG.CommandPlatform.AgentRegistry do
  @moduledoc """
  Tracks connected PTY agents and their metadata.

  Provides agent discovery, routing, and lifecycle management
  for the command platform's terminal agents.
  """

  use GenServer
  require Logger

  @table :agent_registry
  @cleanup_interval :timer.minutes(5)

  defstruct [:agents, :monitors]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new agent with its channel PID.
  """
  def register_agent(agent_id, channel_pid) do
    GenServer.call(__MODULE__, {:register, agent_id, channel_pid})
  end

  @doc """
  Unregisters an agent.
  """
  def unregister_agent(agent_id) do
    GenServer.cast(__MODULE__, {:unregister, agent_id})
  end

  @doc """
  Updates agent metadata/info.
  """
  def update_agent_info(agent_id, info) do
    GenServer.cast(__MODULE__, {:update_info, agent_id, info})
  end

  @doc """
  Records agent heartbeat.
  """
  def heartbeat(agent_id, heartbeat_data) do
    GenServer.cast(__MODULE__, {:heartbeat, agent_id, heartbeat_data})
  end

  @doc """
  Finds an agent by ID and returns its channel PID.
  """
  def find_agent(agent_id) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent}] -> {:ok, agent}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all connected agents.
  """
  def list_agents do
    :ets.tab2list(@table)
    |> Enum.map(fn {_id, agent} -> agent end)
  end

  @doc """
  Counts connected agents.
  """
  def count_agents do
    :ets.info(@table, :size)
  end

  @doc """
  Sends a command to a specific agent.
  """
  def send_to_agent(agent_id, message) do
    case find_agent(agent_id) do
      {:ok, agent} ->
        send(agent.channel_pid, message)
        :ok

      {:error, :not_found} ->
        {:error, :agent_not_found}
    end
  end

  @doc """
  Checks if an agent is connected.
  """
  def agent_connected?(agent_id) do
    case find_agent(agent_id) do
      {:ok, _} -> true
      _ -> false
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Create ETS table for fast lookups
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])

    GSMLG.Telemetry.info("AgentRegistry started", metadata: %{})

    schedule_cleanup()

    {:ok, %__MODULE__{agents: %{}, monitors: %{}}}
  end

  @impl true
  def handle_call({:register, agent_id, channel_pid}, _from, state) do
    # Monitor the channel process
    ref = Process.monitor(channel_pid)

    agent = %{
      agent_id: agent_id,
      channel_pid: channel_pid,
      connected_at: System.system_time(:millisecond),
      last_heartbeat: System.system_time(:millisecond),
      info: %{},
      status: :connected
    }

    :ets.insert(@table, {agent_id, agent})

    new_state = %{
      state
      | agents: Map.put(state.agents, agent_id, agent),
        monitors: Map.put(state.monitors, ref, agent_id)
    }

    GSMLG.Telemetry.info("Agent registered",
      metadata: %{
        agent_id: agent_id,
        pid: inspect(channel_pid)
      }
    )

    # Update old CommandPlatform.Agent for backward compatibility with LiveView
    commander = %{
      name: agent_id,
      socket: channel_pid,
      connected_at: agent.connected_at
    }

    GSMLG.CommandPlatform.commander_joined(commander)

    # Broadcast to admin UI
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "commander_updates",
      :commander_updates
    )

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_cast({:unregister, agent_id}, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:noreply, state}

      _agent ->
        :ets.delete(@table, agent_id)

        # Find and demonitor
        monitor_ref =
          Enum.find_value(state.monitors, fn {ref, id} ->
            if id == agent_id, do: ref
          end)

        new_monitors =
          if monitor_ref do
            Process.demonitor(monitor_ref, [:flush])
            Map.delete(state.monitors, monitor_ref)
          else
            state.monitors
          end

        GSMLG.Telemetry.info("Agent unregistered",
          metadata: %{
            agent_id: agent_id
          }
        )

        # Update old CommandPlatform.Agent for backward compatibility
        commander = %{name: agent_id}
        GSMLG.CommandPlatform.commander_leave(commander)

        # Broadcast to admin UI
        Phoenix.PubSub.broadcast(
          GSMLG.PubSub,
          "commander_updates",
          :commander_updates
        )

        {:noreply, %{state | agents: Map.delete(state.agents, agent_id), monitors: new_monitors}}
    end
  end

  @impl true
  def handle_cast({:update_info, agent_id, info}, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent}] ->
        updated_agent = %{agent | info: Map.merge(agent.info, info)}
        :ets.insert(@table, {agent_id, updated_agent})

        new_agents = Map.put(state.agents, agent_id, updated_agent)
        {:noreply, %{state | agents: new_agents}}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:heartbeat, agent_id, heartbeat_data}, state) do
    case :ets.lookup(@table, agent_id) do
      [{^agent_id, agent}] ->
        updated_agent = %{
          agent
          | last_heartbeat: System.system_time(:millisecond),
            info: Map.merge(agent.info, heartbeat_data)
        }

        :ets.insert(@table, {agent_id, updated_agent})

        new_agents = Map.put(state.agents, agent_id, updated_agent)
        {:noreply, %{state | agents: new_agents}}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      agent_id ->
        GSMLG.Telemetry.warn("Agent channel process died",
          metadata: %{
            agent_id: agent_id
          }
        )

        :ets.delete(@table, agent_id)

        # Update old CommandPlatform.Agent for backward compatibility
        commander = %{name: agent_id}
        GSMLG.CommandPlatform.commander_leave(commander)

        # Broadcast disconnection
        Phoenix.PubSub.broadcast(
          GSMLG.PubSub,
          "commander_updates",
          {:agent_disconnected, agent_id}
        )

        Phoenix.PubSub.broadcast(
          GSMLG.PubSub,
          "commander_updates",
          :commander_updates
        )

        new_state = %{
          state
          | agents: Map.delete(state.agents, agent_id),
            monitors: Map.delete(state.monitors, ref)
        }

        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:millisecond)
    timeout = :timer.minutes(10)

    stale_agents =
      state.agents
      |> Enum.filter(fn {_id, agent} ->
        now - agent.last_heartbeat > timeout
      end)
      |> Enum.map(fn {id, _agent} -> id end)

    Enum.each(stale_agents, fn agent_id ->
      GSMLG.Telemetry.warn("Removing stale agent",
        metadata: %{
          agent_id: agent_id
        }
      )

      :ets.delete(@table, agent_id)
    end)

    new_agents = Map.drop(state.agents, stale_agents)
    schedule_cleanup()

    {:noreply, %{state | agents: new_agents}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end
end
