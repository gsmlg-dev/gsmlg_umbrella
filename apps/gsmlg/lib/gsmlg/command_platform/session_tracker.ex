defmodule GSMLG.CommandPlatform.SessionTracker do
  @moduledoc """
  Tracks PTY sessions across agents with Concord local state.

  Manages session lifecycle, handles reconnection scenarios,
  and provides session discovery and monitoring capabilities.
  """

  use GenServer
  require Logger
  alias GSMLG.CommandPlatform.PTYSessionRecord

  @cleanup_interval :timer.minutes(10)

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Registers a new PTY session.
  """
  def register_session(agent_id, session_id, session_info) do
    GenServer.call(__MODULE__, {:register, agent_id, session_id, session_info})
  end

  @doc """
  Registers a PTY session without blocking the caller.
  """
  def register_session_async(agent_id, session_id, session_info) do
    start_session_task(fn ->
      case write_session(agent_id, session_id, session_info) do
        :ok ->
          :ok

        {:error, reason} ->
          GSMLG.Telemetry.warn("Async session registration failed",
            metadata: %{
              session_id: session_id,
              agent_id: agent_id,
              reason: inspect(reason)
            }
          )
      end
    end)

    :ok
  end

  @doc """
  Updates session activity timestamp.
  """
  def update_activity(agent_id, session_id) do
    GenServer.cast(__MODULE__, {:update_activity, agent_id, session_id})
  end

  @doc """
  Marks a session as closed.
  """
  def close_session(agent_id, session_id, exit_code) do
    GenServer.cast(__MODULE__, {:close, agent_id, session_id, exit_code})
  end

  @doc """
  Synchronizes a session from agent (on reconnect).
  """
  def sync_session(agent_id, session_info) do
    GenServer.cast(__MODULE__, {:sync, agent_id, session_info})
  end

  @doc """
  Finds a session by ID.
  """
  def find_session(session_id) do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} -> {:ok, session}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Lists all sessions, optionally filtered by agent_id or state.
  """
  def list_sessions(opts \\ []) do
    PTYSessionRecord.list(opts)
  end

  @doc """
  Lists sessions for a specific agent.
  """
  def list_agent_sessions(agent_id) do
    PTYSessionRecord.list(agent_id: agent_id)
  end

  @doc """
  Counts sessions.
  """
  def count_sessions(opts \\ []) do
    PTYSessionRecord.count(opts)
  end

  @doc """
  Marks sessions as orphaned when an agent disconnects.
  """
  def mark_agent_sessions_orphaned(agent_id) do
    GenServer.cast(__MODULE__, {:mark_orphaned, agent_id})
  end

  @doc """
  Sets a controller (admin user) for a session.
  """
  def set_controller(session_id, controller_pid) do
    GenServer.cast(__MODULE__, {:set_controller, session_id, controller_pid})
  end

  @doc """
  Clears the controller from a session.
  """
  def clear_controller(session_id) do
    GenServer.cast(__MODULE__, {:clear_controller, session_id})
  end

  @doc """
  Returns statistics about sessions.
  """
  def stats do
    all_sessions = PTYSessionRecord.list()

    %{
      total: length(all_sessions),
      by_state:
        Enum.group_by(all_sessions, & &1.state)
        |> Enum.map(fn {state, list} -> {state, length(list)} end)
        |> Map.new(),
      by_agent:
        Enum.group_by(all_sessions, & &1.agent_id)
        |> Enum.map(fn {agent, list} -> {agent, length(list)} end)
        |> Map.new()
    }
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    GSMLG.Telemetry.info("SessionTracker started", metadata: %{})

    schedule_cleanup()

    {:ok, %{}, {:continue, :ensure_session_store}}
  end

  @impl true
  def handle_continue(:ensure_session_store, state) do
    Task.start(fn ->
      PTYSessionRecord.create_table()
    end)

    {:noreply, state}
  end

  @impl true
  def handle_call({:register, agent_id, session_id, session_info}, _from, state) do
    {:reply, write_session(agent_id, session_id, session_info), state}
  end

  @impl true
  def handle_cast({:update_activity, _agent_id, session_id}, state) do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} ->
        updated = Map.put(session, :last_activity, System.system_time(:millisecond))
        PTYSessionRecord.write(updated)

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:close, _agent_id, session_id, exit_code}, state) do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} ->
        updated = %{
          session
          | state: :closed,
            exit_code: exit_code,
            last_activity: System.system_time(:millisecond)
        }

        PTYSessionRecord.write(updated)

        GSMLG.Telemetry.info("Session closed",
          metadata: %{
            session_id: session_id,
            exit_code: exit_code
          }
        )

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync, agent_id, session_info}, state) do
    session_id = session_info[:session_id] || session_info.session_id

    case PTYSessionRecord.read(session_id) do
      {:ok, existing} ->
        # Session exists, update it
        updated = %{
          existing
          | last_activity: System.system_time(:millisecond),
            state: session_info[:state] || existing.state
        }

        PTYSessionRecord.write(updated)

      {:error, :not_found} ->
        # New session, register it
        write_session(agent_id, session_id, session_info)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:mark_orphaned, agent_id}, state) do
    sessions = PTYSessionRecord.list(agent_id: agent_id)

    Enum.each(sessions, fn session ->
      if session.state in [:running, :attached] do
        updated = %{session | state: :detached}
        PTYSessionRecord.write(updated)

        GSMLG.Telemetry.info("Session marked as orphaned",
          metadata: %{
            session_id: session.session_id,
            agent_id: agent_id
          }
        )
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:set_controller, session_id, controller_pid}, state) do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} ->
        updated = %{session | controller_pid: controller_pid, state: :attached}
        PTYSessionRecord.write(updated)

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:clear_controller, session_id}, state) do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} ->
        updated = %{session | controller_pid: nil, state: :detached}
        PTYSessionRecord.write(updated)

      {:error, _} ->
        :ok
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    # Clean up old closed sessions (older than 24 hours)
    PTYSessionRecord.cleanup_old_sessions(:timer.hours(24))

    GSMLG.Telemetry.debug("Session cleanup completed", metadata: %{})

    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private Functions

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp start_session_task(fun) do
    if Process.whereis(GSMLG.TaskSupervisor) do
      Task.Supervisor.start_child(GSMLG.TaskSupervisor, fun)
    else
      Task.start(fun)
    end
  end

  defp write_session(agent_id, session_id, session_info) do
    session = %{
      session_id: session_id,
      agent_id: agent_id,
      command: get_value(session_info, :command) || "unknown",
      dimensions: get_value(session_info, :dimensions) || %{rows: 24, cols: 80},
      created_at: get_value(session_info, :created_at) || System.system_time(:millisecond),
      last_activity: System.system_time(:millisecond),
      state: get_value(session_info, :state) || :running,
      exit_code: get_value(session_info, :exit_code),
      controller_pid: get_value(session_info, :controller_pid),
      metadata: get_value(session_info, :metadata) || %{}
    }

    case PTYSessionRecord.write(session) do
      :ok ->
        GSMLG.Telemetry.info("Session registered",
          metadata: %{
            session_id: session_id,
            agent_id: agent_id
          }
        )

        :ok

      {:error, reason} = error ->
        GSMLG.Telemetry.error("Failed to register session",
          metadata: %{
            session_id: session_id,
            reason: inspect(reason)
          }
        )

        error
    end
  end

  defp get_value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
