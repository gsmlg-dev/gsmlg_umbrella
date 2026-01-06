defmodule GSMLG.Commander.SessionRegistry do
  @moduledoc """
  Registry for Commander sessions with metadata support and fast lookups.

  Provides unique key registration for sessions with metadata indexing capabilities.
  Sessions can be looked up by:
  - Session ID (unique key)
  - Agent ID
  - Hostname
  - Tags
  - Status
  - User ID

  ## Usage

  The registry is started as part of the Commander supervision tree.
  Sessions register themselves when started.

  ## Examples

      # Register a session
      GSMLG.Commander.SessionRegistry.register(session_id, metadata)

      # Lookup by session ID
      GSMLG.Commander.SessionRegistry.lookup(session_id)

      # Find sessions by hostname
      GSMLG.Commander.SessionRegistry.find_by_hostname("web-01.example.com")

      # Find sessions by tags
      GSMLG.Commander.SessionRegistry.find_by_tags(["production", "web"])

  """

  require GSMLG.Telemetry

  @registry_name __MODULE__
  @ets_index_table :commander_session_index

  @type session_id :: String.t()
  @type metadata :: %{
          optional(:agent_id) => String.t(),
          optional(:hostname) => String.t(),
          optional(:user_id) => String.t(),
          optional(:status) => atom(),
          optional(:tags) => [String.t()],
          optional(:ip) => String.t(),
          optional(:connected_at) => DateTime.t(),
          optional(atom()) => term()
        }

  # ============================================================================
  # Child Spec
  # ============================================================================

  @doc """
  Returns the child spec for the registry.
  """
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :supervisor
    }
  end

  @doc """
  Starts the session registry and associated ETS tables.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @registry_name)

    # Create the index ETS table for fast lookups
    create_index_table()

    # Start the Registry
    Registry.start_link(keys: :unique, name: name)
  end

  # ============================================================================
  # Registration
  # ============================================================================

  @doc """
  Registers a session with the given ID and metadata.

  Returns `{:ok, pid}` on success or `{:error, {:already_registered, pid}}` if
  the session ID is already registered.
  """
  @spec register(session_id(), metadata()) :: {:ok, pid()} | {:error, term()}
  def register(session_id, metadata \\ %{}) do
    case Registry.register(@registry_name, session_id, metadata) do
      {:ok, _pid} = result ->
        update_indexes(session_id, metadata)

        GSMLG.Telemetry.debug("Session registered",
          session_id: session_id,
          agent_id: metadata[:agent_id],
          hostname: metadata[:hostname]
        )

        result

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Unregisters a session.
  """
  @spec unregister(session_id()) :: :ok
  def unregister(session_id) do
    Registry.unregister(@registry_name, session_id)
    remove_from_indexes(session_id)

    GSMLG.Telemetry.debug("Session unregistered", session_id: session_id)

    :ok
  end

  @doc """
  Updates the metadata for a registered session.
  """
  @spec update_metadata(session_id(), metadata()) :: :ok | {:error, :not_found}
  def update_metadata(session_id, metadata) do
    case lookup(session_id) do
      {:ok, _pid, old_metadata} ->
        new_metadata = Map.merge(old_metadata, metadata)
        Registry.update_value(@registry_name, session_id, fn _ -> new_metadata end)
        update_indexes(session_id, new_metadata)
        :ok

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # ============================================================================
  # Lookup Functions
  # ============================================================================

  @doc """
  Looks up a session by ID.

  Returns `{:ok, pid, metadata}` if found, `{:error, :not_found}` otherwise.
  """
  @spec lookup(session_id()) :: {:ok, pid(), metadata()} | {:error, :not_found}
  def lookup(session_id) do
    case Registry.lookup(@registry_name, session_id) do
      [{pid, metadata}] -> {:ok, pid, metadata}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Returns the PID for a session, or nil if not found.
  """
  @spec whereis(session_id()) :: pid() | nil
  def whereis(session_id) do
    case lookup(session_id) do
      {:ok, pid, _} -> pid
      {:error, :not_found} -> nil
    end
  end

  @doc """
  Checks if a session is registered.
  """
  @spec registered?(session_id()) :: boolean()
  def registered?(session_id) do
    case lookup(session_id) do
      {:ok, _, _} -> true
      {:error, :not_found} -> false
    end
  end

  @doc """
  Returns the via tuple for a session.
  """
  @spec via_tuple(session_id()) :: {:via, Registry, {module(), session_id()}}
  def via_tuple(session_id) do
    {:via, Registry, {@registry_name, session_id}}
  end

  # ============================================================================
  # Index-based Lookups
  # ============================================================================

  @doc """
  Finds all sessions for a given agent ID.
  """
  @spec find_by_agent_id(String.t()) :: [{session_id(), pid(), metadata()}]
  def find_by_agent_id(agent_id) do
    case :ets.lookup(@ets_index_table, {:agent_id, agent_id}) do
      [{_, session_ids}] ->
        Enum.flat_map(session_ids, fn session_id ->
          case lookup(session_id) do
            {:ok, pid, metadata} -> [{session_id, pid, metadata}]
            _ -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc """
  Finds all sessions for a given hostname.
  """
  @spec find_by_hostname(String.t()) :: [{session_id(), pid(), metadata()}]
  def find_by_hostname(hostname) do
    case :ets.lookup(@ets_index_table, {:hostname, hostname}) do
      [{_, session_ids}] ->
        Enum.flat_map(session_ids, fn session_id ->
          case lookup(session_id) do
            {:ok, pid, metadata} -> [{session_id, pid, metadata}]
            _ -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc """
  Finds all sessions with a given status.
  """
  @spec find_by_status(atom()) :: [{session_id(), pid(), metadata()}]
  def find_by_status(status) do
    case :ets.lookup(@ets_index_table, {:status, status}) do
      [{_, session_ids}] ->
        Enum.flat_map(session_ids, fn session_id ->
          case lookup(session_id) do
            {:ok, pid, metadata} -> [{session_id, pid, metadata}]
            _ -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc """
  Finds all sessions for a given user ID.
  """
  @spec find_by_user_id(String.t()) :: [{session_id(), pid(), metadata()}]
  def find_by_user_id(user_id) do
    case :ets.lookup(@ets_index_table, {:user_id, user_id}) do
      [{_, session_ids}] ->
        Enum.flat_map(session_ids, fn session_id ->
          case lookup(session_id) do
            {:ok, pid, metadata} -> [{session_id, pid, metadata}]
            _ -> []
          end
        end)

      [] ->
        []
    end
  end

  @doc """
  Finds all sessions that have ALL of the given tags.
  """
  @spec find_by_tags([String.t()]) :: [{session_id(), pid(), metadata()}]
  def find_by_tags([]), do: list_all()

  def find_by_tags(tags) when is_list(tags) do
    # Get sessions for each tag and find intersection
    tag_sessions =
      tags
      |> Enum.map(fn tag ->
        case :ets.lookup(@ets_index_table, {:tag, tag}) do
          [{_, session_ids}] -> MapSet.new(session_ids)
          [] -> MapSet.new()
        end
      end)

    matching_ids =
      case tag_sessions do
        [] ->
          []

        [first | rest] ->
          Enum.reduce(rest, first, &MapSet.intersection/2)
          |> MapSet.to_list()
      end

    Enum.flat_map(matching_ids, fn session_id ->
      case lookup(session_id) do
        {:ok, pid, metadata} -> [{session_id, pid, metadata}]
        _ -> []
      end
    end)
  end

  @doc """
  Finds sessions matching a hostname pattern (supports wildcards).
  """
  @spec find_by_hostname_pattern(String.t()) :: [{session_id(), pid(), metadata()}]
  def find_by_hostname_pattern(pattern) do
    regex = pattern_to_regex(pattern)

    list_all()
    |> Enum.filter(fn {_session_id, _pid, metadata} ->
      hostname = metadata[:hostname] || ""
      Regex.match?(regex, hostname)
    end)
  end

  # ============================================================================
  # Listing Functions
  # ============================================================================

  @doc """
  Lists all registered sessions.
  """
  @spec list_all() :: [{session_id(), pid(), metadata()}]
  def list_all do
    Registry.select(@registry_name, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
  end

  @doc """
  Returns the count of registered sessions.
  """
  @spec count() :: non_neg_integer()
  def count do
    Registry.count(@registry_name)
  end

  @doc """
  Returns counts grouped by status.
  """
  @spec count_by_status() :: %{atom() => non_neg_integer()}
  def count_by_status do
    list_all()
    |> Enum.group_by(fn {_, _, metadata} -> metadata[:status] || :unknown end)
    |> Map.new(fn {status, sessions} -> {status, length(sessions)} end)
  end

  @doc """
  Lists all session IDs.
  """
  @spec list_ids() :: [session_id()]
  def list_ids do
    Registry.select(@registry_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_index_table do
    if :ets.whereis(@ets_index_table) == :undefined do
      :ets.new(@ets_index_table, [:set, :public, :named_table, read_concurrency: true])
    end

    :ok
  end

  defp update_indexes(session_id, metadata) do
    # Update agent_id index
    if agent_id = metadata[:agent_id] do
      add_to_index({:agent_id, agent_id}, session_id)
    end

    # Update hostname index
    if hostname = metadata[:hostname] do
      add_to_index({:hostname, hostname}, session_id)
    end

    # Update status index
    if status = metadata[:status] do
      add_to_index({:status, status}, session_id)
    end

    # Update user_id index
    if user_id = metadata[:user_id] do
      add_to_index({:user_id, user_id}, session_id)
    end

    # Update tag indexes
    if tags = metadata[:tags] do
      Enum.each(tags, fn tag ->
        add_to_index({:tag, tag}, session_id)
      end)
    end

    :ok
  end

  defp add_to_index(key, session_id) do
    case :ets.lookup(@ets_index_table, key) do
      [{_, existing_ids}] ->
        new_ids = MapSet.put(existing_ids, session_id)
        :ets.insert(@ets_index_table, {key, new_ids})

      [] ->
        :ets.insert(@ets_index_table, {key, MapSet.new([session_id])})
    end
  end

  defp remove_from_indexes(session_id) do
    # Get all index entries
    entries = :ets.tab2list(@ets_index_table)

    # Remove session_id from all indexes
    Enum.each(entries, fn {key, session_ids} ->
      new_ids = MapSet.delete(session_ids, session_id)

      if MapSet.size(new_ids) == 0 do
        :ets.delete(@ets_index_table, key)
      else
        :ets.insert(@ets_index_table, {key, new_ids})
      end
    end)

    :ok
  end

  defp pattern_to_regex(pattern) do
    pattern
    |> String.replace(".", "\\.")
    |> String.replace("*", ".*")
    |> String.replace("?", ".")
    |> then(&"^#{&1}$")
    |> Regex.compile!()
  end
end
