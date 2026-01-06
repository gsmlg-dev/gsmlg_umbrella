defmodule GSMLG.Commander.Manager do
  @moduledoc """
  Orchestration layer for Commander sessions.

  The Manager provides:
  - Agent Registry indexing and fast lookups
  - Health monitoring of sessions and agents
  - Audit logging of all operations
  - Resource management and limit enforcement
  - Telemetry aggregation and metrics

  ## Usage

  The Manager is started as part of the Commander supervision tree and provides
  a high-level API for managing sessions.

  ## Examples

      # List all connected agents
      GSMLG.Commander.Manager.list_agents()

      # Find agents by hostname pattern
      GSMLG.Commander.Manager.find_agents(hostname: "web-*.example.com")

      # Get manager statistics
      GSMLG.Commander.Manager.stats()

  """

  use GenServer

  require GSMLG.Telemetry

  alias GSMLG.Commander.{Session, SessionRegistry, SessionSupervisor, Policy}

  @health_check_interval 60_000
  @cleanup_interval 300_000

  # ============================================================================
  # Types
  # ============================================================================

  @type agent_info :: %{
          session_id: String.t(),
          agent_id: String.t(),
          hostname: String.t(),
          status: atom(),
          connected_at: DateTime.t() | nil,
          pty_count: non_neg_integer(),
          metadata: map()
        }

  @type filter :: [
          {:hostname, String.t()}
          | {:hostname_pattern, String.t()}
          | {:agent_id, String.t()}
          | {:tags, [String.t()]}
          | {:status, atom()}
          | {:user_id, String.t()}
        ]

  # ============================================================================
  # Client API
  # ============================================================================

  @doc """
  Starts the Manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new session for an incoming agent connection.

  ## Options

    * `:agent_id` - unique identifier for the agent
    * `:hostname` - hostname of the agent
    * `:connection_pid` - WebSocket handler PID
    * `:user_id` - owner user ID
    * `:metadata` - additional metadata

  """
  @spec create_session(keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_session(opts) do
    GenServer.call(__MODULE__, {:create_session, opts})
  end

  @doc """
  Terminates a session.
  """
  @spec terminate_session(String.t(), atom()) :: :ok | {:error, :not_found}
  def terminate_session(session_id, reason \\ :normal) do
    GenServer.call(__MODULE__, {:terminate_session, session_id, reason})
  end

  @doc """
  Authenticates a session with credentials.
  """
  @spec authenticate_session(String.t(), map()) :: :ok | {:error, term()}
  def authenticate_session(session_id, credentials) do
    GenServer.call(__MODULE__, {:authenticate_session, session_id, credentials})
  end

  @doc """
  Lists all agents with optional filtering.
  """
  @spec list_agents(filter()) :: [agent_info()]
  def list_agents(filter \\ []) do
    GenServer.call(__MODULE__, {:list_agents, filter})
  end

  @doc """
  Finds agents matching the given criteria.
  """
  @spec find_agents(filter()) :: [agent_info()]
  def find_agents(filter) do
    list_agents(filter)
  end

  @doc """
  Gets detailed information about a specific agent/session.
  """
  @spec get_agent(String.t()) :: {:ok, agent_info()} | {:error, :not_found}
  def get_agent(session_id) do
    GenServer.call(__MODULE__, {:get_agent, session_id})
  end

  @doc """
  Returns manager statistics.
  """
  @spec stats() :: map()
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @doc """
  Returns health status of all agents.
  """
  @spec health_report() :: map()
  def health_report do
    GenServer.call(__MODULE__, :health_report)
  end

  @doc """
  Spawns a PTY on an agent.

  Requires authorization check against Policy.
  """
  @spec spawn_pty(String.t(), String.t(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def spawn_pty(session_id, user_id, opts \\ %{}) do
    GenServer.call(__MODULE__, {:spawn_pty, session_id, user_id, opts})
  end

  @doc """
  Broadcasts a message to all connected agents matching the filter.
  """
  @spec broadcast(term(), filter()) :: :ok
  def broadcast(message, filter \\ []) do
    GenServer.cast(__MODULE__, {:broadcast, message, filter})
  end

  @doc """
  Gets audit log entries.
  """
  @spec get_audit_log(keyword()) :: [map()]
  def get_audit_log(opts \\ []) do
    GenServer.call(__MODULE__, {:get_audit_log, opts})
  end

  # ============================================================================
  # Server Callbacks
  # ============================================================================

  @impl true
  def init(opts) do
    state = %{
      audit_log: [],
      audit_log_max_size: Keyword.get(opts, :audit_log_max_size, 10_000),
      metrics: %{
        sessions_created: 0,
        sessions_terminated: 0,
        auth_successes: 0,
        auth_failures: 0,
        ptys_spawned: 0
      }
    }

    # Schedule periodic tasks
    schedule_health_check()
    schedule_cleanup()

    GSMLG.Telemetry.info("Commander Manager started")

    {:ok, state}
  end

  @impl true
  def handle_call({:create_session, opts}, _from, state) do
    session_id = opts[:session_id] || generate_session_id()
    session_opts = Keyword.put(opts, :session_id, session_id)

    case SessionSupervisor.start_session(session_opts) do
      {:ok, _pid} ->
        audit_log(state, :session_created, %{
          session_id: session_id,
          agent_id: opts[:agent_id],
          hostname: opts[:hostname]
        })

        new_state = update_metric(state, :sessions_created)

        GSMLG.Telemetry.info("Session created via manager",
          session_id: session_id,
          agent_id: opts[:agent_id]
        )

        {:reply, {:ok, session_id}, new_state}

      {:error, reason} = error ->
        GSMLG.Telemetry.error("Failed to create session",
          reason: inspect(reason)
        )

        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:terminate_session, session_id, reason}, _from, state) do
    case SessionSupervisor.terminate_session_by_id(session_id) do
      :ok ->
        audit_log(state, :session_terminated, %{
          session_id: session_id,
          reason: reason
        })

        new_state = update_metric(state, :sessions_terminated)
        {:reply, :ok, new_state}

      {:error, :not_found} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:authenticate_session, session_id, credentials}, _from, state) do
    case Session.authenticate(session_id, credentials) do
      :ok ->
        audit_log(state, :session_authenticated, %{
          session_id: session_id,
          agent_id: credentials[:agent_id]
        })

        new_state = update_metric(state, :auth_successes)
        {:reply, :ok, new_state}

      {:error, reason} = error ->
        audit_log(state, :auth_failed, %{
          session_id: session_id,
          reason: reason
        })

        new_state = update_metric(state, :auth_failures)
        {:reply, error, new_state}
    end
  end

  @impl true
  def handle_call({:list_agents, filter}, _from, state) do
    agents =
      SessionRegistry.list_all()
      |> Enum.map(&session_to_agent_info/1)
      |> apply_filters(filter)

    {:reply, agents, state}
  end

  @impl true
  def handle_call({:get_agent, session_id}, _from, state) do
    case SessionRegistry.lookup(session_id) do
      {:ok, _pid, metadata} ->
        case Session.get_info(session_id) do
          {:ok, info} ->
            agent_info = %{
              session_id: session_id,
              agent_id: metadata[:agent_id],
              hostname: metadata[:hostname],
              status: info.status,
              connected_at: info.connected_at,
              pty_count: info.pty_count,
              metadata: info.metadata
            }

            {:reply, {:ok, agent_info}, state}

          {:error, _} = error ->
            {:reply, error, state}
        end

      {:error, :not_found} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:stats, _from, state) do
    session_stats = SessionSupervisor.stats()
    registry_count = SessionRegistry.count()
    status_counts = SessionRegistry.count_by_status()

    stats = %{
      sessions: %{
        active: session_stats.active,
        max_allowed: session_stats.max_children,
        by_status: status_counts
      },
      registry: %{
        total: registry_count
      },
      metrics: state.metrics,
      audit_log_size: length(state.audit_log)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:health_report, _from, state) do
    sessions = SessionRegistry.list_all()

    now = DateTime.utc_now()

    health =
      Enum.map(sessions, fn {session_id, _pid, metadata} ->
        case Session.get_info(session_id) do
          {:ok, info} ->
            age =
              if info.connected_at do
                DateTime.diff(now, info.connected_at, :second)
              else
                0
              end

            heartbeat_age =
              if info.last_heartbeat do
                DateTime.diff(now, info.last_heartbeat, :second)
              else
                nil
              end

            health_status =
              cond do
                info.status == :disconnected -> :unhealthy
                heartbeat_age && heartbeat_age > 120 -> :degraded
                true -> :healthy
              end

            %{
              session_id: session_id,
              agent_id: metadata[:agent_id],
              hostname: metadata[:hostname],
              status: info.status,
              health: health_status,
              uptime_seconds: age,
              heartbeat_age_seconds: heartbeat_age
            }

          {:error, _} ->
            %{
              session_id: session_id,
              agent_id: metadata[:agent_id],
              health: :unknown
            }
        end
      end)

    summary = %{
      healthy: Enum.count(health, &(&1.health == :healthy)),
      degraded: Enum.count(health, &(&1.health == :degraded)),
      unhealthy: Enum.count(health, &(&1.health == :unhealthy)),
      unknown: Enum.count(health, &(&1.health == :unknown))
    }

    {:reply, %{sessions: health, summary: summary}, state}
  end

  @impl true
  def handle_call({:spawn_pty, session_id, user_id, opts}, _from, state) do
    with {:ok, _pid, metadata} <- SessionRegistry.lookup(session_id),
         :ok <- Policy.authorize(:spawn_pty, user_id, metadata),
         {:ok, pty_id} <- Session.spawn_pty(session_id, opts) do
      audit_log(state, :pty_spawned, %{
        session_id: session_id,
        user_id: user_id,
        pty_id: pty_id
      })

      new_state = update_metric(state, :ptys_spawned)
      {:reply, {:ok, pty_id}, new_state}
    else
      {:error, :not_found} ->
        {:reply, {:error, :session_not_found}, state}

      {:error, :unauthorized} = error ->
        audit_log(state, :unauthorized_pty_spawn, %{
          session_id: session_id,
          user_id: user_id
        })

        {:reply, error, state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:get_audit_log, opts}, _from, state) do
    limit = Keyword.get(opts, :limit, 100)
    since = Keyword.get(opts, :since)

    log =
      state.audit_log
      |> maybe_filter_since(since)
      |> Enum.take(limit)

    {:reply, log, state}
  end

  @impl true
  def handle_cast({:broadcast, message, filter}, state) do
    sessions =
      SessionRegistry.list_all()
      |> apply_filters(filter)

    Enum.each(sessions, fn agent_info ->
      case SessionRegistry.whereis(agent_info.session_id) do
        nil -> :ok
        pid -> send(pid, {:broadcast, message})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    perform_health_check()
    schedule_health_check()
    {:noreply, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    perform_cleanup()
    schedule_cleanup()
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp generate_session_id do
    timestamp = System.system_time(:millisecond)
    random = :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
    "session_#{timestamp}_#{random}"
  end

  defp session_to_agent_info({session_id, _pid, metadata}) do
    %{
      session_id: session_id,
      agent_id: metadata[:agent_id],
      hostname: metadata[:hostname],
      status: metadata[:status] || :unknown,
      connected_at: metadata[:connected_at],
      pty_count: 0,
      metadata: metadata,
      tags: metadata[:tags] || []
    }
  end

  defp apply_filters(agents, []), do: agents

  defp apply_filters(agents, [{:hostname, hostname} | rest]) do
    agents
    |> Enum.filter(&(&1.hostname == hostname))
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [{:hostname_pattern, pattern} | rest]) do
    regex = pattern_to_regex(pattern)

    agents
    |> Enum.filter(fn agent ->
      agent.hostname && Regex.match?(regex, agent.hostname)
    end)
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [{:agent_id, agent_id} | rest]) do
    agents
    |> Enum.filter(&(&1.agent_id == agent_id))
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [{:status, status} | rest]) do
    agents
    |> Enum.filter(&(&1.status == status))
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [{:user_id, user_id} | rest]) do
    agents
    |> Enum.filter(&(get_in(&1, [:metadata, :user_id]) == user_id))
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [{:tags, tags} | rest]) when is_list(tags) do
    agents
    |> Enum.filter(fn agent ->
      agent_tags = agent.tags || []
      Enum.all?(tags, &(&1 in agent_tags))
    end)
    |> apply_filters(rest)
  end

  defp apply_filters(agents, [_ | rest]) do
    apply_filters(agents, rest)
  end

  defp pattern_to_regex(pattern) do
    pattern
    |> String.replace(".", "\\.")
    |> String.replace("*", ".*")
    |> String.replace("?", ".")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end

  defp audit_log(_state, event, details) do
    entry = %{
      timestamp: DateTime.utc_now(),
      event: event,
      details: details
    }

    GSMLG.Telemetry.debug("Audit log",
      event: event,
      details: details
    )

    # Emit telemetry event
    :telemetry.execute(
      [:commander, :audit, event],
      %{count: 1},
      details
    )

    entry
  end

  defp update_metric(state, metric) do
    new_metrics = Map.update(state.metrics, metric, 1, &(&1 + 1))
    %{state | metrics: new_metrics}
  end

  defp maybe_filter_since(log, nil), do: log

  defp maybe_filter_since(log, since) do
    Enum.filter(log, fn entry ->
      DateTime.compare(entry.timestamp, since) != :lt
    end)
  end

  defp schedule_health_check do
    Process.send_after(self(), :health_check, @health_check_interval)
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval)
  end

  defp perform_health_check do
    sessions = SessionRegistry.list_all()

    unhealthy =
      Enum.filter(sessions, fn {session_id, _pid, metadata} ->
        metadata[:status] == :disconnected
      end)

    if length(unhealthy) > 0 do
      GSMLG.Telemetry.warn("Unhealthy sessions detected",
        count: length(unhealthy)
      )
    end

    :telemetry.execute(
      [:commander, :manager, :health_check],
      %{
        total_sessions: length(sessions),
        unhealthy_sessions: length(unhealthy)
      },
      %{}
    )
  end

  defp perform_cleanup do
    # Clean up stale index entries
    GSMLG.Telemetry.debug("Performing manager cleanup")

    :telemetry.execute(
      [:commander, :manager, :cleanup],
      %{count: 1},
      %{}
    )
  end
end
