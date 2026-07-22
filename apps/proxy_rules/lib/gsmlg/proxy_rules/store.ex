defmodule GSMLG.ProxyRules.Store do
  use GenServer

  alias GSMLG.ProxyRules.{Configuration, Persistence, Snapshot}

  @table :gsmlg_proxy_rules_store
  @readiness [:not_ready, :refreshing, :ready, :stale]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec current() :: {:ok, Snapshot.t()} | {:error, :not_ready}
  def current do
    case :ets.lookup(@table, :current) do
      [{:current, snapshot}] when is_map(snapshot) -> {:ok, snapshot}
      [] -> {:error, :not_ready}
    end
  rescue
    ArgumentError -> {:error, :not_ready}
  end

  @spec publish(Snapshot.t()) :: :ok | {:error, :invalid_snapshot | :persistence_failed}
  def publish(snapshot), do: GenServer.call(__MODULE__, {:publish, snapshot})

  @spec update_status(Snapshot.readiness(), nil | Snapshot.operational_error()) ::
          :ok | {:error, :invalid_readiness | :invalid_operational_error}
  def update_status(readiness, operational_error),
    do: GenServer.call(__MODULE__, {:update_status, readiness, operational_error})

  @spec metadata() :: {:ok, map()}
  def metadata, do: GenServer.call(__MODULE__, :metadata)

  @impl true
  def init(opts) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])

    state_directory = state_directory(opts)
    persistence_options = Keyword.get(opts, :persistence_options, [])
    _ = recover(state_directory, persistence_options)
    {snapshot, operational_status} = restore(state_directory)

    if snapshot, do: :ets.insert(@table, {:current, snapshot})

    {:ok,
     %{
       state_directory: state_directory,
       persistence_options: persistence_options,
       readiness: if(snapshot, do: snapshot.readiness, else: :not_ready),
       operational_status: operational_status
     }}
  end

  @impl true
  def handle_call({:publish, snapshot}, _from, state) do
    if Persistence.valid_snapshot?(snapshot) do
      case persist(state.state_directory, snapshot, state.persistence_options) do
        :ok ->
          true = :ets.insert(@table, {:current, snapshot})
          {:reply, :ok, %{state | readiness: snapshot.readiness, operational_status: nil}}

        {:error, :persistence_failed} = error ->
          readiness = mark_current_stale(:persistence_failed)
          status = %{kind: :persistence, reason: :persistence_failed}
          {:reply, error, %{state | readiness: readiness, operational_status: status}}
      end
    else
      {:reply, {:error, :invalid_snapshot}, state}
    end
  end

  def handle_call({:update_status, readiness, operational_error}, _from, state) do
    cond do
      readiness not in @readiness ->
        {:reply, {:error, :invalid_readiness}, state}

      not valid_operational_error?(operational_error) ->
        {:reply, {:error, :invalid_operational_error}, state}

      true ->
        case current() do
          {:ok, snapshot} ->
            updated = %{snapshot | readiness: readiness, last_error: operational_error}
            true = :ets.insert(@table, {:current, updated})
            {:reply, :ok, %{state | readiness: readiness, operational_status: operational_error}}

          {:error, :not_ready} ->
            readiness = readiness_without_artifact(readiness)

            {:reply, :ok, %{state | readiness: readiness, operational_status: operational_error}}
        end
    end
  end

  def handle_call(:metadata, _from, state) do
    metadata =
      case current() do
        {:ok, snapshot} -> Snapshot.metadata(snapshot)
        {:error, :not_ready} -> %{readiness: state.readiness}
      end

    metadata =
      if state.operational_status,
        do: Map.put(metadata, :operational_status, state.operational_status),
        else: metadata

    {:reply, {:ok, metadata}, state}
  end

  defp state_directory(opts) do
    case Keyword.fetch(opts, :state_directory) do
      {:ok, directory} when is_binary(directory) -> directory
      _other -> configured_state_directory()
    end
  end

  defp configured_state_directory do
    case Configuration.load() do
      {:ok, %Configuration{state_directory: directory}} -> directory
      {:error, _reason} -> nil
    end
  end

  defp restore(nil),
    do: {nil, %{kind: :store, reason: :configuration_unavailable}}

  defp restore(state_directory) do
    case Persistence.read_artifact(state_directory) do
      {:ok, snapshot} -> {%{snapshot | readiness: :stale}, nil}
      {:error, reason} -> {nil, %{kind: :store, reason: reason}}
    end
  end

  defp persist(nil, _snapshot, _opts), do: {:error, :persistence_failed}

  defp persist(state_directory, snapshot, opts) do
    with :ok <- Persistence.recover_artifact(state_directory, opts),
         :ok <- Persistence.write_artifact(state_directory, snapshot, opts) do
      :ok
    end
  end

  defp recover(nil, _opts), do: {:error, :persistence_failed}
  defp recover(state_directory, opts), do: Persistence.recover_artifact(state_directory, opts)

  defp mark_current_stale(reason) do
    case current() do
      {:ok, snapshot} ->
        stale = %{
          snapshot
          | readiness: :stale,
            last_error: %{kind: :persistence, reason: reason}
        }

        true = :ets.insert(@table, {:current, stale})
        :stale

      {:error, :not_ready} ->
        :not_ready
    end
  end

  defp readiness_without_artifact(:refreshing), do: :refreshing
  defp readiness_without_artifact(_readiness), do: :not_ready

  defp valid_operational_error?(nil), do: true
  defp valid_operational_error?(error), do: Snapshot.valid_operational_error?(error)
end
