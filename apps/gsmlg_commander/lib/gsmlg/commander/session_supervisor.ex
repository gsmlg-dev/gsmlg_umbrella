defmodule GSMLG.Commander.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for Commander sessions.

  Manages the lifecycle of session GenServers with:
  - :temporary restart strategy (no auto-restart on crash)
  - Configurable max_children limit
  - Telemetry integration for monitoring

  Sessions are not restarted automatically because:
  1. They represent WebSocket connections that need re-establishment
  2. Client reconnection logic handles recovery
  3. Orphaned sessions would waste resources
  """

  use DynamicSupervisor

  require GSMLG.Telemetry

  @default_max_children 10_000

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the session supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Starts a new session under the supervisor.

  ## Options

    * `:session_id` - unique identifier for the session (required)
    * `:agent_id` - the agent this session represents
    * `:user_id` - the user who owns the session
    * `:hostname` - the hostname of the agent
    * `:connection_pid` - the WebSocket handler PID
    * `:metadata` - additional metadata

  ## Returns

    * `{:ok, pid}` - session started successfully
    * `{:error, :max_children}` - supervisor at capacity
    * `{:error, {:already_started, pid}}` - session already exists
    * `{:error, reason}` - other error

  """
  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) do
    session_id = Keyword.fetch!(opts, :session_id)

    GSMLG.Telemetry.debug("Starting session",
      session_id: session_id,
      agent_id: opts[:agent_id]
    )

    spec = {GSMLG.Commander.Session, opts}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} = result ->
        emit_session_started(session_id, opts)
        result

      {:error, {:already_started, _pid}} = error ->
        GSMLG.Telemetry.warn("Session already started",
          session_id: session_id
        )

        error

      {:error, :max_children} = error ->
        GSMLG.Telemetry.error("Session supervisor at capacity",
          session_id: session_id,
          max_children: get_max_children()
        )

        error

      {:error, reason} = error ->
        GSMLG.Telemetry.error("Failed to start session",
          session_id: session_id,
          reason: inspect(reason)
        )

        error
    end
  end

  @doc """
  Terminates a session.
  """
  @spec terminate_session(pid()) :: :ok | {:error, :not_found}
  def terminate_session(pid) when is_pid(pid) do
    case DynamicSupervisor.terminate_child(__MODULE__, pid) do
      :ok ->
        emit_session_terminated(pid)
        :ok

      {:error, :not_found} = error ->
        error
    end
  end

  @doc """
  Terminates a session by session ID.
  """
  @spec terminate_session_by_id(String.t()) :: :ok | {:error, :not_found}
  def terminate_session_by_id(session_id) do
    case GSMLG.Commander.SessionRegistry.whereis(session_id) do
      nil ->
        {:error, :not_found}

      pid ->
        terminate_session(pid)
    end
  end

  @doc """
  Returns the number of active sessions.
  """
  @spec count_children() :: non_neg_integer()
  def count_children do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Returns detailed statistics about the supervisor.
  """
  @spec stats() :: map()
  def stats do
    counts = DynamicSupervisor.count_children(__MODULE__)

    %{
      active: counts.active,
      specs: counts.specs,
      supervisors: counts.supervisors,
      workers: counts.workers,
      max_children: get_max_children()
    }
  end

  @doc """
  Lists all session PIDs.
  """
  @spec list_sessions() :: [pid()]
  def list_sessions do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.flat_map(fn
      {:undefined, pid, :worker, _} when is_pid(pid) -> [pid]
      _ -> []
    end)
  end

  @doc """
  Checks if the supervisor can accept more children.
  """
  @spec at_capacity?() :: boolean()
  def at_capacity? do
    count_children() >= get_max_children()
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    max_children = Keyword.get(opts, :max_children, get_max_children())

    GSMLG.Telemetry.info("Session supervisor starting",
      max_children: max_children
    )

    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: 0,
      max_seconds: 1,
      extra_arguments: [],
      max_children: max_children
    )
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp get_max_children do
    config = Application.get_env(:gsmlg_commander, :server, [])
    Keyword.get(config, :max_agents, @default_max_children)
  end

  defp emit_session_started(session_id, opts) do
    :telemetry.execute(
      [:commander, :session, :started],
      %{count: 1},
      %{
        session_id: session_id,
        agent_id: opts[:agent_id],
        hostname: opts[:hostname]
      }
    )
  end

  defp emit_session_terminated(pid) do
    :telemetry.execute(
      [:commander, :session, :terminated],
      %{count: 1},
      %{pid: pid}
    )
  end
end
