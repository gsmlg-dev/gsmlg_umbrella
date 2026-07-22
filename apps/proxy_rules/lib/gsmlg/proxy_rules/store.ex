defmodule GSMLG.ProxyRules.Store do
  use GenServer

  alias GSMLG.ProxyRules.{Configuration, Persistence, Snapshot}

  @table :gsmlg_proxy_rules_store
  @readiness [:not_ready, :refreshing, :ready, :stale]

  def start_link(opts) do
    {gen_options, init_options} = Keyword.split(opts, [:name])

    GenServer.start_link(
      __MODULE__,
      init_options,
      Keyword.put_new(gen_options, :name, __MODULE__)
    )
  end

  @spec current() :: {:ok, Snapshot.t()} | {:error, :not_ready}
  def current do
    case :ets.lookup(@table, :current) do
      [{:current, snapshot}] when is_map(snapshot) -> {:ok, snapshot}
      [] -> {:error, :not_ready}
    end
  rescue
    ArgumentError -> {:error, :not_ready}
  end

  @spec current(GenServer.server()) :: {:ok, Snapshot.t()} | {:error, :not_ready}
  def current(server), do: GenServer.call(server, :current)

  @type stage_token :: {:proxy_rules_stage, pos_integer(), non_neg_integer()}

  @spec stage_token(non_neg_integer()) :: stage_token()
  def stage_token(generation) when is_integer(generation) and generation >= 0,
    do: {:proxy_rules_stage, System.unique_integer([:positive, :monotonic]), generation}

  @spec stage(GenServer.server(), Snapshot.t()) ::
          {:ok, stage_token()} | {:error, :invalid_snapshot | :persistence_failed}
  def stage(server, snapshot), do: GenServer.call(server, {:stage, snapshot}, :infinity)

  @spec stage(GenServer.server(), stage_token(), Snapshot.t()) ::
          {:ok, stage_token()}
          | {:error, :invalid_snapshot | :invalid_stage | :persistence_failed}
  def stage(server, token, snapshot),
    do: GenServer.call(server, {:stage, token, snapshot}, :infinity)

  @spec commit(GenServer.server(), stage_token()) ::
          :ok | {:error, :invalid_stage | :persistence_failed}
  def commit(server, token), do: GenServer.call(server, {:commit, token}, :infinity)

  @spec finalize(GenServer.server(), stage_token()) ::
          :ok | {:error, :invalid_stage | :persistence_failed}
  def finalize(server, token), do: GenServer.call(server, {:finalize, token}, :infinity)

  @spec discard(GenServer.server(), stage_token()) :: :ok
  def discard(server, token), do: GenServer.call(server, {:discard, token})

  @spec publish(Snapshot.t()) :: :ok | {:error, :invalid_snapshot | :persistence_failed}
  def publish(snapshot), do: GenServer.call(__MODULE__, {:publish, snapshot})

  @spec update_status(Snapshot.readiness(), nil | Snapshot.operational_error()) ::
          :ok | {:error, :invalid_readiness | :invalid_operational_error}
  def update_status(readiness, operational_error),
    do: GenServer.call(__MODULE__, {:update_status, readiness, operational_error})

  @spec update_status(
          GenServer.server(),
          Snapshot.readiness(),
          nil | Snapshot.operational_error()
        ) ::
          :ok | {:error, :invalid_readiness | :invalid_operational_error}
  def update_status(server, readiness, operational_error),
    do: GenServer.call(server, {:update_status, readiness, operational_error})

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
       operational_status: operational_status,
       staged: %{}
     }}
  end

  def handle_call(:current, _from, state), do: {:reply, current(), state}

  def handle_call({:stage, snapshot}, from, state) do
    if match?(%Snapshot{}, snapshot) do
      handle_call({:stage, stage_token(snapshot.generation), snapshot}, from, state)
    else
      {:reply, {:error, :invalid_snapshot}, state}
    end
  end

  def handle_call(
        {:stage, {:proxy_rules_stage, id, generation} = token, snapshot},
        _from,
        state
      )
      when is_integer(id) and id > 0 and is_integer(generation) and generation >= 0 do
    cond do
      not Persistence.valid_snapshot?(snapshot) ->
        {:reply, {:error, :invalid_snapshot}, state}

      generation != snapshot.generation or Map.has_key?(state.staged, token) ->
        {:reply, {:error, :invalid_stage}, state}

      not is_binary(state.state_directory) ->
        {:reply, {:error, :persistence_failed}, state}

      true ->
        directory = Path.join(state.state_directory, ".artifact-stage-#{id}")

        case Persistence.write_artifact(directory, snapshot, state.persistence_options) do
          :ok ->
            staged =
              Map.put(state.staged, token, %{
                snapshot: snapshot,
                directory: directory,
                status: :staged
              })

            {:reply, {:ok, token}, %{state | staged: staged}}

          {:error, _reason} ->
            {:reply, {:error, :persistence_failed}, state}
        end
    end
  end

  def handle_call({:stage, _token, _snapshot}, _from, state),
    do: {:reply, {:error, :invalid_stage}, state}

  def handle_call({:finalize, token}, _from, state) do
    case Map.fetch(state.staged, token) do
      {:ok, %{status: :staged, directory: directory} = entry} ->
        staged_path = Path.join(directory, "artifact.snapshot")

        case Persistence.finalize_staged_artifact(
               state.state_directory,
               staged_path,
               state.persistence_options
             ) do
          :ok ->
            staged = Map.put(state.staged, token, %{entry | status: :finalized})
            {:reply, :ok, %{state | staged: staged}}

          {:error, :persistence_failed} = error ->
            {:reply, error, state}
        end

      {:ok, %{status: :finalized}} ->
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :invalid_stage}, state}
    end
  end

  def handle_call({:commit, token}, _from, state) do
    case Map.fetch(state.staged, token) do
      {:ok, %{status: :finalized, snapshot: snapshot, directory: directory}} ->
        true = :ets.insert(@table, {:current, snapshot})
        _ = File.rmdir(directory)

        {:reply, :ok,
         %{
           state
           | staged: Map.delete(state.staged, token),
             readiness: snapshot.readiness,
             operational_status: nil
         }}

      {:ok, %{status: :staged}} ->
        {:reply, {:error, :invalid_stage}, state}

      :error ->
        {:reply, {:error, :invalid_stage}, state}
    end
  end

  def handle_call({:discard, token}, _from, state) do
    case Map.pop(state.staged, token) do
      {nil, staged} ->
        {:reply, :ok, %{state | staged: staged}}

      {%{status: :staged, directory: directory}, staged} ->
        _ = File.rm(Path.join(directory, "artifact.snapshot"))
        _ = File.rmdir(directory)
        {:reply, :ok, %{state | staged: staged}}

      {%{status: :finalized, directory: directory}, staged} ->
        _ = File.rmdir(directory)
        {:reply, :ok, %{state | staged: staged}}
    end
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
