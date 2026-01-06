defmodule GSMLG.Commander.Session do
  @moduledoc """
  GenServer representing a server-side Commander session.

  Manages the lifecycle of an agent connection including:
  - Connection state tracking with status transitions
  - Multiple PTY sessions per agent
  - Heartbeat monitoring
  - Idle timeout handling
  - Output buffering during operator disconnects
  - Telemetry event emission

  ## State Machine

  ```
  :pending -> :active -> :disconnected -> :terminated
                 |              |
                 +--------------+
  ```

  - `:pending` - Session created, waiting for authentication
  - `:active` - Fully connected and operational
  - `:disconnected` - Connection lost, waiting for reconnection
  - `:terminated` - Session ended, cleanup in progress

  ## PTY Sessions

  Each session can have multiple concurrent PTY sessions (terminals).
  PTY sessions are identified by a unique pty_id and track:
  - Operator PIDs attached to the PTY
  - Terminal dimensions
  - Output buffer for replay
  - Activity timestamps
  """

  use GenServer

  require GSMLG.Telemetry

  alias GSMLG.Commander.{SessionRegistry, Protocol}

  # Timeouts
  @heartbeat_interval 30_000
  @heartbeat_timeout 90_000
  @reconnect_grace_period 120_000
  @idle_timeout 3_600_000

  # Buffer limits
  @max_output_buffer_bytes 1_048_576
  @max_ptys_per_agent 10

  # Status transitions
  @valid_transitions %{
    pending: [:active, :terminated],
    active: [:disconnected, :terminated],
    disconnected: [:active, :terminated],
    terminated: []
  }

  # ============================================================================
  # Types
  # ============================================================================

  @type session_id :: String.t()
  @type pty_id :: non_neg_integer()
  @type status :: :pending | :active | :disconnected | :terminated

  @type pty_session :: %{
          id: pty_id(),
          operator_pids: [pid()],
          dimensions: %{cols: pos_integer(), rows: pos_integer()},
          output_buffer: binary(),
          created_at: DateTime.t(),
          last_activity: DateTime.t()
        }

  @type state :: %{
          id: session_id(),
          agent_id: String.t() | nil,
          user_id: String.t() | nil,
          hostname: String.t() | nil,
          status: status(),
          connection_pid: pid() | nil,
          pty_sessions: %{pty_id() => pty_session()},
          metadata: map(),
          operator_pids: [pid()],
          connected_at: DateTime.t() | nil,
          last_heartbeat: DateTime.t() | nil,
          heartbeat_timer: reference() | nil,
          reconnect_timer: reference() | nil,
          idle_timer: reference() | nil
        }

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts a new session GenServer.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    session_id = Keyword.fetch!(opts, :session_id)
    GenServer.start_link(__MODULE__, opts, name: via_tuple(session_id))
  end

  @doc """
  Gets the session state.
  """
  @spec get_state(session_id()) :: {:ok, state()} | {:error, :not_found}
  def get_state(session_id) do
    GenServer.call(via_tuple(session_id), :get_state)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Gets session info (public subset of state).
  """
  @spec get_info(session_id()) :: {:ok, map()} | {:error, :not_found}
  def get_info(session_id) do
    GenServer.call(via_tuple(session_id), :get_info)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Authenticates and activates the session.
  """
  @spec authenticate(session_id(), map()) :: :ok | {:error, term()}
  def authenticate(session_id, credentials) do
    GenServer.call(via_tuple(session_id), {:authenticate, credentials})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Updates the connection PID (used during reconnection).
  """
  @spec update_connection(session_id(), pid()) :: :ok | {:error, term()}
  def update_connection(session_id, connection_pid) do
    GenServer.call(via_tuple(session_id), {:update_connection, connection_pid})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Records a heartbeat from the agent.
  """
  @spec heartbeat(session_id()) :: :ok
  def heartbeat(session_id) do
    GenServer.cast(via_tuple(session_id), :heartbeat)
  end

  @doc """
  Updates session metadata.
  """
  @spec update_metadata(session_id(), map()) :: :ok | {:error, :not_found}
  def update_metadata(session_id, metadata) do
    GenServer.call(via_tuple(session_id), {:update_metadata, metadata})
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  @doc """
  Terminates the session.
  """
  @spec terminate_session(session_id(), atom()) :: :ok
  def terminate_session(session_id, reason \\ :normal) do
    GenServer.cast(via_tuple(session_id), {:terminate, reason})
  end

  # ============================================================================
  # PTY Session Management
  # ============================================================================

  @doc """
  Spawns a new PTY session.
  """
  @spec spawn_pty(session_id(), map()) :: {:ok, pty_id()} | {:error, term()}
  def spawn_pty(session_id, opts \\ %{}) do
    GenServer.call(via_tuple(session_id), {:spawn_pty, opts})
  catch
    :exit, {:noproc, _} -> {:error, :session_not_found}
  end

  @doc """
  Sends input to a PTY session.
  """
  @spec send_pty_input(session_id(), pty_id(), binary()) :: :ok | {:error, term()}
  def send_pty_input(session_id, pty_id, data) do
    GenServer.cast(via_tuple(session_id), {:pty_input, pty_id, data})
  end

  @doc """
  Receives output from a PTY session (called by agent).
  """
  @spec receive_pty_output(session_id(), pty_id(), binary()) :: :ok
  def receive_pty_output(session_id, pty_id, data) do
    GenServer.cast(via_tuple(session_id), {:pty_output, pty_id, data})
  end

  @doc """
  Resizes a PTY session.
  """
  @spec resize_pty(session_id(), pty_id(), pos_integer(), pos_integer()) ::
          :ok | {:error, term()}
  def resize_pty(session_id, pty_id, cols, rows) do
    GenServer.call(via_tuple(session_id), {:resize_pty, pty_id, cols, rows})
  catch
    :exit, {:noproc, _} -> {:error, :session_not_found}
  end

  @doc """
  Kills a PTY session.
  """
  @spec kill_pty(session_id(), pty_id(), pos_integer()) :: :ok | {:error, term()}
  def kill_pty(session_id, pty_id, signal \\ 15) do
    GenServer.call(via_tuple(session_id), {:kill_pty, pty_id, signal})
  catch
    :exit, {:noproc, _} -> {:error, :session_not_found}
  end

  @doc """
  Attaches an operator to a PTY session.
  """
  @spec attach_operator(session_id(), pty_id(), pid()) :: :ok | {:error, term()}
  def attach_operator(session_id, pty_id, operator_pid) do
    GenServer.call(via_tuple(session_id), {:attach_operator, pty_id, operator_pid})
  catch
    :exit, {:noproc, _} -> {:error, :session_not_found}
  end

  @doc """
  Detaches an operator from a PTY session.
  """
  @spec detach_operator(session_id(), pty_id(), pid()) :: :ok
  def detach_operator(session_id, pty_id, operator_pid) do
    GenServer.cast(via_tuple(session_id), {:detach_operator, pty_id, operator_pid})
  end

  @doc """
  Lists all PTY sessions for a session.
  """
  @spec list_ptys(session_id()) :: {:ok, [pty_session()]} | {:error, :not_found}
  def list_ptys(session_id) do
    GenServer.call(via_tuple(session_id), :list_ptys)
  catch
    :exit, {:noproc, _} -> {:error, :not_found}
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    session_id = Keyword.fetch!(opts, :session_id)

    state = %{
      id: session_id,
      agent_id: Keyword.get(opts, :agent_id),
      user_id: Keyword.get(opts, :user_id),
      hostname: Keyword.get(opts, :hostname),
      status: :pending,
      connection_pid: Keyword.get(opts, :connection_pid),
      pty_sessions: %{},
      metadata: Keyword.get(opts, :metadata, %{}),
      operator_pids: [],
      connected_at: nil,
      last_heartbeat: nil,
      heartbeat_timer: nil,
      reconnect_timer: nil,
      idle_timer: nil
    }

    # Register with SessionRegistry
    registry_metadata = %{
      agent_id: state.agent_id,
      hostname: state.hostname,
      user_id: state.user_id,
      status: state.status,
      tags: get_in(state.metadata, [:tags]) || []
    }

    case SessionRegistry.register(session_id, registry_metadata) do
      {:ok, _} ->
        # Monitor connection if provided
        if state.connection_pid do
          Process.monitor(state.connection_pid)
        end

        emit_telemetry(:session_created, state)

        GSMLG.Telemetry.info("Session created",
          session_id: session_id,
          agent_id: state.agent_id,
          hostname: state.hostname
        )

        {:ok, state}

      {:error, {:already_registered, _}} ->
        {:stop, :already_registered}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, {:ok, state}, state}
  end

  @impl true
  def handle_call(:get_info, _from, state) do
    info = %{
      id: state.id,
      agent_id: state.agent_id,
      hostname: state.hostname,
      status: state.status,
      pty_count: map_size(state.pty_sessions),
      connected_at: state.connected_at,
      last_heartbeat: state.last_heartbeat,
      metadata: state.metadata
    }

    {:reply, {:ok, info}, state}
  end

  @impl true
  def handle_call({:authenticate, credentials}, _from, state) do
    case transition_status(state, :active) do
      {:ok, new_state} ->
        authenticated_state = %{
          new_state
          | agent_id: credentials[:agent_id] || state.agent_id,
            hostname: credentials[:hostname] || state.hostname,
            connected_at: DateTime.utc_now(),
            last_heartbeat: DateTime.utc_now()
        }

        # Start heartbeat monitoring
        final_state = schedule_heartbeat_check(authenticated_state)

        # Update registry
        SessionRegistry.update_metadata(state.id, %{
          agent_id: final_state.agent_id,
          hostname: final_state.hostname,
          status: :active
        })

        emit_telemetry(:session_authenticated, final_state)

        GSMLG.Telemetry.info("Session authenticated",
          session_id: state.id,
          agent_id: final_state.agent_id
        )

        {:reply, :ok, final_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:update_connection, connection_pid}, _from, state) do
    # Monitor new connection
    Process.monitor(connection_pid)

    # Cancel reconnect timer if any
    new_state =
      state
      |> cancel_timer(:reconnect_timer)
      |> Map.put(:connection_pid, connection_pid)

    # Transition back to active if disconnected
    case transition_status(new_state, :active) do
      {:ok, active_state} ->
        active_state = schedule_heartbeat_check(active_state)
        SessionRegistry.update_metadata(state.id, %{status: :active})
        emit_telemetry(:session_reconnected, active_state)

        GSMLG.Telemetry.info("Session reconnected",
          session_id: state.id
        )

        {:reply, :ok, active_state}

      {:error, _} ->
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:update_metadata, metadata}, _from, state) do
    new_metadata = Map.merge(state.metadata, metadata)
    new_state = %{state | metadata: new_metadata}

    SessionRegistry.update_metadata(state.id, metadata)

    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:spawn_pty, opts}, _from, state) do
    if map_size(state.pty_sessions) >= @max_ptys_per_agent do
      {:reply, {:error, :max_ptys_reached}, state}
    else
      pty_id = Protocol.generate_pty_id()

      # Ensure unique pty_id
      pty_id =
        if Map.has_key?(state.pty_sessions, pty_id) do
          Protocol.generate_pty_id()
        else
          pty_id
        end

      pty_session = %{
        id: pty_id,
        operator_pids: [],
        dimensions: opts[:dimensions] || %{cols: 80, rows: 24},
        output_buffer: "",
        created_at: DateTime.utc_now(),
        last_activity: DateTime.utc_now()
      }

      new_state = put_in(state.pty_sessions[pty_id], pty_session)

      # Send spawn request to agent
      if state.connection_pid do
        send(state.connection_pid, {:send_to_agent, :pty_spawn, pty_id, opts})
      end

      emit_telemetry(:pty_spawned, %{session_id: state.id, pty_id: pty_id})

      GSMLG.Telemetry.debug("PTY spawned",
        session_id: state.id,
        pty_id: pty_id
      )

      {:reply, {:ok, pty_id}, new_state}
    end
  end

  @impl true
  def handle_call({:resize_pty, pty_id, cols, rows}, _from, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, pty_session} ->
        new_pty = %{pty_session | dimensions: %{cols: cols, rows: rows}}
        new_state = put_in(state.pty_sessions[pty_id], new_pty)

        # Send resize to agent
        if state.connection_pid do
          send(state.connection_pid, {:send_to_agent, :pty_resize, pty_id, %{cols: cols, rows: rows}})
        end

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :pty_not_found}, state}
    end
  end

  @impl true
  def handle_call({:kill_pty, pty_id, signal}, _from, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, _pty_session} ->
        # Send kill to agent
        if state.connection_pid do
          send(state.connection_pid, {:send_to_agent, :pty_kill, pty_id, %{signal: signal}})
        end

        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :pty_not_found}, state}
    end
  end

  @impl true
  def handle_call({:attach_operator, pty_id, operator_pid}, _from, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, pty_session} ->
        # Monitor operator
        Process.monitor(operator_pid)

        # Add to operator list
        new_operators = [operator_pid | pty_session.operator_pids] |> Enum.uniq()
        new_pty = %{pty_session | operator_pids: new_operators}
        new_state = put_in(state.pty_sessions[pty_id], new_pty)

        # Send buffered output
        if byte_size(pty_session.output_buffer) > 0 do
          send(operator_pid, {:pty_output, pty_id, pty_session.output_buffer})
        end

        {:reply, :ok, new_state}

      :error ->
        {:reply, {:error, :pty_not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_ptys, _from, state) do
    ptys = Map.values(state.pty_sessions)
    {:reply, {:ok, ptys}, state}
  end

  @impl true
  def handle_cast(:heartbeat, state) do
    new_state = %{state | last_heartbeat: DateTime.utc_now()}
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:pty_input, pty_id, data}, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, pty_session} ->
        # Update activity timestamp
        new_pty = %{pty_session | last_activity: DateTime.utc_now()}
        new_state = put_in(state.pty_sessions[pty_id], new_pty)

        # Forward to agent
        if state.connection_pid do
          send(state.connection_pid, {:send_to_agent, :pty_input, pty_id, data})
        end

        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:pty_output, pty_id, data}, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, pty_session} ->
        # Buffer output
        new_buffer = truncate_buffer(pty_session.output_buffer <> data)
        new_pty = %{pty_session | output_buffer: new_buffer, last_activity: DateTime.utc_now()}
        new_state = put_in(state.pty_sessions[pty_id], new_pty)

        # Broadcast to operators
        Enum.each(pty_session.operator_pids, fn pid ->
          send(pid, {:pty_output, pty_id, data})
        end)

        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:detach_operator, pty_id, operator_pid}, state) do
    case Map.fetch(state.pty_sessions, pty_id) do
      {:ok, pty_session} ->
        new_operators = List.delete(pty_session.operator_pids, operator_pid)
        new_pty = %{pty_session | operator_pids: new_operators}
        new_state = put_in(state.pty_sessions[pty_id], new_pty)
        {:noreply, new_state}

      :error ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:terminate, reason}, state) do
    GSMLG.Telemetry.info("Session terminating",
      session_id: state.id,
      reason: reason
    )

    {:stop, reason, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) when pid == state.connection_pid do
    GSMLG.Telemetry.warn("Connection lost",
      session_id: state.id
    )

    case transition_status(state, :disconnected) do
      {:ok, new_state} ->
        new_state =
          new_state
          |> Map.put(:connection_pid, nil)
          |> cancel_timer(:heartbeat_timer)
          |> schedule_reconnect_timeout()

        SessionRegistry.update_metadata(state.id, %{status: :disconnected})
        emit_telemetry(:session_disconnected, new_state)

        {:noreply, new_state}

      {:error, _} ->
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    # Operator disconnected - remove from all PTY sessions
    new_pty_sessions =
      Map.new(state.pty_sessions, fn {pty_id, pty_session} ->
        new_operators = List.delete(pty_session.operator_pids, pid)
        {pty_id, %{pty_session | operator_pids: new_operators}}
      end)

    {:noreply, %{state | pty_sessions: new_pty_sessions}}
  end

  @impl true
  def handle_info(:heartbeat_check, state) do
    if state.status == :active do
      heartbeat_age =
        if state.last_heartbeat do
          DateTime.diff(DateTime.utc_now(), state.last_heartbeat, :millisecond)
        else
          @heartbeat_timeout + 1
        end

      if heartbeat_age > @heartbeat_timeout do
        GSMLG.Telemetry.warn("Heartbeat timeout",
          session_id: state.id,
          age_ms: heartbeat_age
        )

        # Treat as disconnection
        case transition_status(state, :disconnected) do
          {:ok, new_state} ->
            new_state = schedule_reconnect_timeout(new_state)
            SessionRegistry.update_metadata(state.id, %{status: :disconnected})
            {:noreply, new_state}

          {:error, _} ->
            {:stop, :heartbeat_timeout, state}
        end
      else
        new_state = schedule_heartbeat_check(state)
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reconnect_timeout, state) do
    GSMLG.Telemetry.info("Reconnect grace period expired",
      session_id: state.id
    )

    emit_telemetry(:session_expired, state)
    {:stop, :reconnect_timeout, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    GSMLG.Telemetry.info("Session idle timeout",
      session_id: state.id
    )

    emit_telemetry(:session_idle_timeout, state)
    {:stop, :idle_timeout, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(reason, state) do
    GSMLG.Telemetry.info("Session terminated",
      session_id: state.id,
      reason: inspect(reason)
    )

    # Unregister from registry
    SessionRegistry.unregister(state.id)

    # Notify operators
    Enum.each(state.pty_sessions, fn {pty_id, pty_session} ->
      Enum.each(pty_session.operator_pids, fn pid ->
        send(pid, {:session_terminated, state.id, pty_id, reason})
      end)
    end)

    emit_telemetry(:session_terminated, state)
    :ok
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp via_tuple(session_id) do
    SessionRegistry.via_tuple(session_id)
  end

  defp transition_status(state, new_status) do
    valid = Map.get(@valid_transitions, state.status, [])

    if new_status in valid do
      {:ok, %{state | status: new_status}}
    else
      {:error, {:invalid_transition, state.status, new_status}}
    end
  end

  defp schedule_heartbeat_check(state) do
    state = cancel_timer(state, :heartbeat_timer)
    timer = Process.send_after(self(), :heartbeat_check, @heartbeat_interval)
    %{state | heartbeat_timer: timer}
  end

  defp schedule_reconnect_timeout(state) do
    state = cancel_timer(state, :reconnect_timer)
    timer = Process.send_after(self(), :reconnect_timeout, @reconnect_grace_period)
    %{state | reconnect_timer: timer}
  end

  defp cancel_timer(state, timer_key) do
    if timer = Map.get(state, timer_key) do
      Process.cancel_timer(timer)
    end

    Map.put(state, timer_key, nil)
  end

  defp truncate_buffer(buffer) when byte_size(buffer) > @max_output_buffer_bytes do
    # Keep last N bytes
    start = byte_size(buffer) - @max_output_buffer_bytes
    binary_part(buffer, start, @max_output_buffer_bytes)
  end

  defp truncate_buffer(buffer), do: buffer

  defp emit_telemetry(event, state) do
    :telemetry.execute(
      [:commander, :session, event],
      %{count: 1},
      %{
        session_id: state.id,
        agent_id: state.agent_id,
        hostname: state.hostname,
        status: state.status
      }
    )
  end
end
