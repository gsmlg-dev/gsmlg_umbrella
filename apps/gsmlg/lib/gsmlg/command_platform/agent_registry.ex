defmodule GSMLG.CommandPlatform.AgentRegistry do
  @moduledoc """
  Tracks connected Commander control channels and their metadata.

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
    case activate_agent(agent_id, channel_pid, %{}, {:legacy, channel_pid}) do
      {:ok, _generation} -> :ok
      error -> error
    end
  end

  def activate_agent(agent_id, channel_pid, info) do
    activate_agent(agent_id, channel_pid, info, {:legacy, channel_pid})
  end

  def activate_agent(agent_id, channel_pid, info, connection_id) do
    GenServer.call(__MODULE__, {:activate, agent_id, channel_pid, info, connection_id})
  end

  @doc """
  Unregisters an agent.
  """
  def unregister_agent(agent_id, channel_pid \\ nil) do
    GenServer.call(__MODULE__, {:unregister, agent_id, channel_pid, nil})
  end

  def unregister_agent(agent_id, channel_pid, generation) do
    GenServer.call(__MODULE__, {:unregister, agent_id, channel_pid, generation})
  end

  def current?(agent_id, channel_pid, generation) do
    case find_agent(agent_id) do
      {:ok, %{channel_pid: ^channel_pid, generation: ^generation}} -> true
      _ -> false
    end
  end

  def current?(agent_id, channel_pid, generation, connection_id) do
    case find_agent(agent_id) do
      {:ok,
       %{
         channel_pid: ^channel_pid,
         generation: ^generation,
         connection_id: ^connection_id
       }} ->
        true

      _ ->
        false
    end
  end

  def attach_terminal(agent_id, terminal_pid, connection_id) do
    GenServer.call(__MODULE__, {:attach_terminal, agent_id, terminal_pid, connection_id})
  end

  def detach_terminal(agent_id, terminal_pid, connection_id, generation) do
    GenServer.call(
      __MODULE__,
      {:detach_terminal, agent_id, terminal_pid, connection_id, generation}
    )
  end

  def current_terminal?(agent_id, terminal_pid, connection_id, generation) do
    case find_agent(agent_id) do
      {:ok,
       %{
         terminal_pid: ^terminal_pid,
         connection_id: ^connection_id,
         generation: ^generation
       }} ->
        true

      _ ->
        false
    end
  end

  def fenced_heartbeat(agent_id, channel_pid, generation, heartbeat_data) do
    fenced_heartbeat(agent_id, channel_pid, generation, {:legacy, channel_pid}, heartbeat_data)
  end

  def fenced_heartbeat(agent_id, channel_pid, generation, connection_id, heartbeat_data) do
    GenServer.call(
      __MODULE__,
      {:heartbeat, agent_id, channel_pid, generation, connection_id, heartbeat_data}
    )
  end

  def fenced_capabilities_update(agent_id, channel_pid, generation, capability_info) do
    fenced_capabilities_update(
      agent_id,
      channel_pid,
      generation,
      {:legacy, channel_pid},
      capability_info
    )
  end

  def fenced_capabilities_update(
        agent_id,
        channel_pid,
        generation,
        connection_id,
        capability_info
      ) do
    GenServer.call(
      __MODULE__,
      {:capabilities_update, agent_id, channel_pid, generation, connection_id, capability_info}
    )
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

  def send_to_terminal(agent_id, message) do
    case find_agent(agent_id) do
      {:ok, %{terminal_pid: terminal_pid}} when is_pid(terminal_pid) ->
        send(terminal_pid, message)
        :ok

      {:ok, _agent} ->
        {:error, :terminal_not_connected}

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
  def handle_call({:activate, agent_id, channel_pid, info, connection_id}, _from, state) do
    {monitors, old_agent} = remove_existing_monitors(state, agent_id)
    if old_agent, do: orphan_agent_sessions(agent_id)
    ref = Process.monitor(channel_pid)
    generation = System.unique_integer([:positive, :monotonic])

    agent = %{
      agent_id: agent_id,
      channel_pid: channel_pid,
      connection_id: connection_id,
      terminal_pid: nil,
      generation: generation,
      connected_at: System.system_time(:millisecond),
      last_heartbeat: System.system_time(:millisecond),
      info: info,
      status: :connected
    }

    :ets.insert(@table, {agent_id, agent})

    new_state = %{
      state
      | agents: Map.put(state.agents, agent_id, agent),
        monitors: Map.put(monitors, ref, {:control, agent_id, generation})
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

    {:reply, {:ok, generation}, new_state}
  end

  def handle_call({:attach_terminal, agent_id, terminal_pid, connection_id}, _from, state) do
    case Map.get(state.agents, agent_id) do
      %{connection_id: ^connection_id, generation: generation} = agent ->
        monitors = remove_terminal_monitor(state.monitors, agent_id, generation)
        ref = Process.monitor(terminal_pid)
        updated_agent = %{agent | terminal_pid: terminal_pid}
        :ets.insert(@table, {agent_id, updated_agent})

        {:reply, {:ok, generation},
         %{
           state
           | agents: Map.put(state.agents, agent_id, updated_agent),
             monitors: Map.put(monitors, ref, {:terminal, agent_id, generation})
         }}

      _ ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call(
        {:detach_terminal, agent_id, terminal_pid, connection_id, generation},
        _from,
        state
      ) do
    case Map.get(state.agents, agent_id) do
      %{
        terminal_pid: ^terminal_pid,
        connection_id: ^connection_id,
        generation: ^generation
      } = agent ->
        monitors = remove_terminal_monitor(state.monitors, agent_id, generation)
        updated_agent = %{agent | terminal_pid: nil}
        :ets.insert(@table, {agent_id, updated_agent})

        {:reply, :ok,
         %{state | agents: Map.put(state.agents, agent_id, updated_agent), monitors: monitors}}

      _ ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call({:unregister, agent_id, channel_pid, generation}, _from, state) do
    case Map.get(state.agents, agent_id) do
      %{channel_pid: current_pid, generation: current_generation}
      when (is_nil(channel_pid) or current_pid == channel_pid) and
             (is_nil(generation) or current_generation == generation) ->
        {:reply, :ok, remove_agent(state, agent_id, :unregistered)}

      nil ->
        {:reply, :ok, state}

      _stale ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call(
        {:heartbeat, agent_id, channel_pid, generation, connection_id, heartbeat_data},
        _from,
        state
      ) do
    case Map.get(state.agents, agent_id) do
      %{
        channel_pid: ^channel_pid,
        generation: ^generation,
        connection_id: ^connection_id
      } = agent ->
        tls_changed? = tls_summary_changed?(agent.info, heartbeat_data)

        updated_agent = %{
          agent
          | last_heartbeat: System.system_time(:millisecond),
            info: Map.merge(agent.info, heartbeat_data)
        }

        :ets.insert(@table, {agent_id, updated_agent})
        if tls_changed?, do: broadcast_commander_updates()
        {:reply, :ok, %{state | agents: Map.put(state.agents, agent_id, updated_agent)}}

      _ ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  def handle_call(
        {:capabilities_update, agent_id, channel_pid, generation, connection_id, capability_info},
        _from,
        state
      ) do
    case Map.get(state.agents, agent_id) do
      %{
        channel_pid: ^channel_pid,
        generation: ^generation,
        connection_id: ^connection_id
      } = agent ->
        updated_agent = %{agent | info: Map.merge(agent.info, capability_info)}
        :ets.insert(@table, {agent_id, updated_agent})

        Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)

        {:reply, :ok, %{state | agents: Map.put(state.agents, agent_id, updated_agent)}}

      _ ->
        {:reply, {:error, :stale_generation}, state}
    end
  end

  @impl true
  def handle_cast({:unregister, agent_id, channel_pid}, state) do
    case Map.get(state.agents, agent_id) do
      nil ->
        {:noreply, state}

      %{channel_pid: current_pid} when not is_nil(channel_pid) and current_pid != channel_pid ->
        {:noreply, state}

      _agent ->
        {:noreply, remove_agent(state, agent_id, :unregistered)}
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
        tls_changed? = tls_summary_changed?(agent.info, heartbeat_data)

        updated_agent = %{
          agent
          | last_heartbeat: System.system_time(:millisecond),
            info: Map.merge(agent.info, heartbeat_data)
        }

        :ets.insert(@table, {agent_id, updated_agent})
        if tls_changed?, do: broadcast_commander_updates()

        new_agents = Map.put(state.agents, agent_id, updated_agent)
        {:noreply, %{state | agents: new_agents}}

      [] ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.monitors, ref) do
      nil ->
        {:noreply, state}

      {:control, agent_id, generation} ->
        case Map.get(state.agents, agent_id) do
          %{channel_pid: ^pid, generation: ^generation} ->
            {:noreply, remove_agent(state, agent_id, :down)}

          _replacement ->
            {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
        end

      {:terminal, agent_id, generation} ->
        case Map.get(state.agents, agent_id) do
          %{terminal_pid: ^pid, generation: ^generation} = agent ->
            updated_agent = %{agent | terminal_pid: nil}
            :ets.insert(@table, {agent_id, updated_agent})

            {:noreply,
             %{
               state
               | agents: Map.put(state.agents, agent_id, updated_agent),
                 monitors: Map.delete(state.monitors, ref)
             }}

          _replacement ->
            {:noreply, %{state | monitors: Map.delete(state.monitors, ref)}}
        end
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

    state = Enum.reduce(stale_agents, state, &remove_agent(&2, &1, :stale))
    schedule_cleanup()

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp remove_existing_monitors(state, agent_id) do
    monitors =
      Enum.reduce(state.monitors, state.monitors, fn
        {ref, {_kind, ^agent_id, _generation}}, acc ->
          Process.demonitor(ref, [:flush])
          Map.delete(acc, ref)

        {_entry, _identity}, acc ->
          acc
      end)

    {monitors, Map.get(state.agents, agent_id)}
  end

  defp remove_terminal_monitor(monitors, agent_id, generation) do
    case Enum.find(monitors, fn
           {_ref, {:terminal, ^agent_id, ^generation}} -> true
           _entry -> false
         end) do
      {ref, _identity} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitors, ref)

      nil ->
        monitors
    end
  end

  defp remove_agent(state, agent_id, reason) do
    case Map.get(state.agents, agent_id) do
      nil ->
        state

      agent ->
        if Process.whereis(GSMLG.CommandPlatform.SessionTracker) do
          GSMLG.CommandPlatform.SessionTracker.mark_agent_sessions_orphaned(agent_id)
        end

        :ets.delete(@table, agent_id)

        agent_generation = agent.generation

        monitors =
          Enum.reduce(state.monitors, state.monitors, fn
            {ref, {_kind, ^agent_id, ^agent_generation}}, acc ->
              Process.demonitor(ref, [:flush])
              Map.delete(acc, ref)

            {_entry, _identity}, acc ->
              acc
          end)

        GSMLG.Telemetry.info("Agent unregistered",
          metadata: %{agent_id: agent_id, reason: reason}
        )

        GSMLG.CommandPlatform.commander_leave(%{name: agent_id})

        Phoenix.PubSub.broadcast(
          GSMLG.PubSub,
          "commander_updates",
          {:agent_disconnected, agent_id}
        )

        Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)

        %{state | agents: Map.delete(state.agents, agent_id), monitors: monitors}
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp tls_summary_changed?(current_info, heartbeat_data) do
    case Map.fetch(heartbeat_data, :tls) do
      {:ok, tls} -> Map.get(current_info, :tls) != tls
      :error -> false
    end
  end

  defp broadcast_commander_updates do
    Phoenix.PubSub.broadcast(GSMLG.PubSub, "commander_updates", :commander_updates)
  end

  defp orphan_agent_sessions(agent_id) do
    if Process.whereis(GSMLG.CommandPlatform.SessionTracker) do
      GSMLG.CommandPlatform.SessionTracker.mark_agent_sessions_orphaned(agent_id)
    end
  end
end
