defmodule GSMLG.Commander.SessionManager do
  @moduledoc """
  Manages PTY sessions using a DynamicSupervisor.

  Provides session lifecycle management including creation, lookup,
  listing, and cleanup. Enforces resource limits and tracks session state.
  """

  use DynamicSupervisor
  require Logger
  alias GSMLG.Commander.{PTYSession, Protocol}

  @max_sessions 50

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  # Client API

  @doc """
  Creates a new PTY session.

  Returns `{:ok, session_id}` on success or `{:error, reason}` on failure.
  """
  def create_session(opts) do
    with :ok <- check_session_limit(),
         {:ok, session_id} <- ensure_session_id(opts),
         :ok <- validate_command(opts[:command]) do
      session_opts = Keyword.put(opts, :session_id, session_id)

      case DynamicSupervisor.start_child(__MODULE__, {PTYSession, session_opts}) do
        {:ok, _pid} ->
          GSMLG.Telemetry.info("PTY session created", %{session_id: session_id})
          {:ok, session_id}

        {:error, reason} ->
          GSMLG.Telemetry.error("Failed to create PTY session",
            metadata: %{
              session_id: session_id,
              reason: inspect(reason)
            }
          )

          {:error, reason}
      end
    end
  end

  @doc """
  Terminates a PTY session.
  """
  def terminate_session(session_id, force \\ false) do
    case find_session(session_id) do
      {:ok, pid} ->
        PTYSession.close(session_id, force)
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Finds a session by ID and returns its pid.
  """
  def find_session(session_id) do
    case Registry.lookup(GSMLG.Commander.SessionRegistry, session_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Lists all active sessions with their metadata.
  """
  def list_sessions do
    Registry.select(GSMLG.Commander.SessionRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.map(fn session_id ->
      case PTYSession.get_info(session_id) do
        info when is_map(info) -> info
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Gets detailed information about a specific session.
  """
  def get_session_info(session_id) do
    case find_session(session_id) do
      {:ok, _pid} -> PTYSession.get_info(session_id)
      {:error, :not_found} -> {:error, :session_not_found}
    end
  end

  @doc """
  Counts active sessions.
  """
  def session_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Sends input to a specific session.
  """
  def send_input(session_id, data) do
    case find_session(session_id) do
      {:ok, _pid} ->
        PTYSession.send_input(session_id, data)
        :ok

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Resizes a session's terminal.
  """
  def resize_session(session_id, rows, cols) do
    case find_session(session_id) do
      {:ok, _pid} ->
        PTYSession.resize(session_id, rows, cols)
        :ok

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Attaches a controlling process to a session.
  """
  def attach_session(session_id, terminal_pid) do
    case find_session(session_id) do
      {:ok, _pid} ->
        PTYSession.attach(session_id, terminal_pid)

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Detaches the controlling process from a session.
  """
  def detach_session(session_id) do
    case find_session(session_id) do
      {:ok, _pid} ->
        PTYSession.detach(session_id)

      {:error, :not_found} ->
        {:error, :session_not_found}
    end
  end

  @doc """
  Cleans up idle or orphaned sessions.
  """
  def cleanup_idle_sessions do
    sessions = list_sessions()
    now = System.system_time(:millisecond)
    idle_threshold = :timer.minutes(30)

    Enum.each(sessions, fn session ->
      idle_time = now - session.last_activity

      if idle_time > idle_threshold and session.state == :detached do
        GSMLG.Telemetry.info("Cleaning up idle session",
          metadata: %{
            session_id: session.session_id,
            idle_time: idle_time
          }
        )

        terminate_session(session.session_id)
      end
    end)
  end

  @doc """
  Returns statistics about sessions.
  """
  def stats do
    sessions = list_sessions()

    %{
      total: length(sessions),
      by_state:
        Enum.group_by(sessions, & &1.state)
        |> Enum.map(fn {state, list} -> {state, length(list)} end)
        |> Map.new(),
      oldest:
        sessions
        |> Enum.min_by(& &1.created_at, fn -> nil end)
        |> case do
          nil -> nil
          session -> session.created_at
        end,
      memory_usage: :erlang.memory(:processes)
    }
  end

  # Private Functions

  defp check_session_limit do
    if session_count() >= @max_sessions do
      GSMLG.Telemetry.warn("Session limit reached",
        metadata: %{
          current: session_count(),
          max: @max_sessions
        }
      )

      {:error, :session_limit_reached}
    else
      :ok
    end
  end

  defp ensure_session_id(opts) do
    case Keyword.get(opts, :session_id) do
      nil ->
        agent_name = Application.get_env(:gsmlg_commander, :name, "unknown")
        session_id = Protocol.generate_session_id(agent_name)
        {:ok, session_id}

      session_id ->
        {:ok, session_id}
    end
  end

  defp validate_command(nil), do: {:error, :command_required}

  defp validate_command(command) when is_binary(command) do
    cond do
      String.trim(command) == "" ->
        {:error, :empty_command}

      String.length(command) > 10_000 ->
        {:error, :command_too_long}

      true ->
        :ok
    end
  end

  defp validate_command(_), do: {:error, :invalid_command_type}
end
