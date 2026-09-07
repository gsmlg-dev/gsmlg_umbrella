defmodule GSMLG.BrowserAgent.ProfileLeaseServer do
  @moduledoc "Serializes and durably persists authoritative profile lease transitions."

  use GenServer

  alias GSMLG.BrowserAgent.{Journal, ProfileLease}

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def acquire(server \\ __MODULE__, profile_id, owner_type, owner_id, opts \\ []) do
    GenServer.call(server, {:acquire, profile_id, owner_type, owner_id, opts})
  end

  def manual_handoff(
        server \\ __MODULE__,
        profile_id,
        automation_lease_id,
        operator_id,
        opts \\ []
      ) do
    GenServer.call(
      server,
      {:manual_handoff, profile_id, automation_lease_id, operator_id, opts}
    )
  end

  def resume(server \\ __MODULE__, profile_id, manual_lease_id, opts \\ []) do
    GenServer.call(server, {:resume, profile_id, manual_lease_id, opts})
  end

  def heartbeat(server \\ __MODULE__, profile_id, lease_id, opts \\ []) do
    GenServer.call(server, {:heartbeat, profile_id, lease_id, opts})
  end

  def reconcile(server \\ __MODULE__, profile_id, execution_active?, opts \\ []) do
    GenServer.call(server, {:reconcile, profile_id, execution_active?, opts})
  end

  def release(server \\ __MODULE__, profile_id, lease_id) do
    GenServer.call(server, {:release, profile_id, lease_id})
  end

  def get(server \\ __MODULE__, profile_id), do: GenServer.call(server, {:get, profile_id})
  def list(server \\ __MODULE__), do: GenServer.call(server, :list)

  def run_unleased(server \\ __MODULE__, profile_id, operation) when is_function(operation, 0) do
    GenServer.call(server, {:run_unleased, profile_id, operation}, :infinity)
  end

  def run_global_launch(server \\ __MODULE__, operation) when is_function(operation, 0) do
    GenServer.call(server, {:run_global_launch, operation}, :infinity)
  end

  @impl true
  def init(opts) do
    journal = Keyword.get(opts, :journal, Journal)
    leases = journal |> Journal.list(:profile_lease) |> Map.new()

    {:ok,
     %{
       journal: journal,
       leases: leases,
       clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
       id_generator: Keyword.get(opts, :id_generator, &generate_id/0),
       default_ttl_ms: Keyword.get(opts, :default_ttl_ms, 7_200_000)
     }}
  end

  @impl true
  def handle_call({:acquire, profile_id, owner_type, owner_id, opts}, _from, state) do
    current = Map.get(state.leases, profile_id)

    transition =
      ProfileLease.acquire(current,
        profile_id: profile_id,
        lease_id: option(opts, :lease_id, state.id_generator),
        owner_type: owner_type,
        owner_id: owner_id,
        mode: Keyword.get(opts, :mode, default_mode(owner_type)),
        now: option(opts, :now, state.clock),
        ttl_ms: Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
      )

    reply_transition(state, profile_id, transition)
  end

  def handle_call(
        {:manual_handoff, profile_id, automation_lease_id, operator_id, opts},
        _from,
        state
      ) do
    transition =
      case Map.get(state.leases, profile_id) do
        %ProfileLease{lease_id: ^automation_lease_id} = current ->
          ProfileLease.manual_handoff(current,
            lease_id: option(opts, :lease_id, state.id_generator),
            owner_id: operator_id,
            now: option(opts, :now, state.clock),
            ttl_ms: Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
          )

        _missing_or_changed ->
          {:error, :lease_conflict}
      end

    reply_transition(state, profile_id, transition)
  end

  def handle_call({:resume, profile_id, manual_lease_id, opts}, _from, state) do
    transition =
      case Map.get(state.leases, profile_id) do
        %ProfileLease{
          lease_id: ^manual_lease_id,
          owner_type: :manual,
          suspended: nil
        } ->
          ProfileLease.acquire(nil,
            profile_id: profile_id,
            lease_id: option(opts, :lease_id, state.id_generator),
            owner_type: :automation,
            owner_id: Keyword.fetch!(opts, :owner_id),
            mode: Keyword.fetch!(opts, :mode),
            now: option(opts, :now, state.clock),
            ttl_ms: Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
          )

        %ProfileLease{lease_id: ^manual_lease_id} = current ->
          ProfileLease.resume(current,
            lease_id: option(opts, :lease_id, state.id_generator),
            now: option(opts, :now, state.clock),
            ttl_ms: Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
          )

        _missing_or_changed ->
          {:error, :lease_conflict}
      end

    reply_transition(state, profile_id, transition)
  end

  def handle_call({:heartbeat, profile_id, lease_id, opts}, _from, state) do
    transition =
      case Map.get(state.leases, profile_id) do
        %ProfileLease{} = current ->
          ProfileLease.heartbeat(
            current,
            lease_id,
            option(opts, :now, state.clock),
            Keyword.get(opts, :ttl_ms, state.default_ttl_ms)
          )

        nil ->
          {:error, :lease_not_found}
      end

    reply_transition(state, profile_id, transition)
  end

  def handle_call({:reconcile, profile_id, execution_active?, opts}, _from, state) do
    transition =
      case Map.get(state.leases, profile_id) do
        %ProfileLease{} = current ->
          ProfileLease.reconcile(current,
            execution_active?: execution_active?,
            now: option(opts, :now, state.clock)
          )

        nil ->
          {:ok, nil}
      end

    reply_transition(state, profile_id, transition)
  end

  def handle_call({:release, profile_id, lease_id}, _from, state) do
    transition =
      case Map.get(state.leases, profile_id) do
        %ProfileLease{} = current -> ProfileLease.release(current, lease_id)
        nil -> {:error, :lease_not_found}
      end

    case persist_transition(state, profile_id, transition) do
      {:ok, nil, state} -> {:reply, :ok, state}
      {:ok, lease, state} -> {:reply, {:ok, lease}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get, profile_id}, _from, state) do
    case Map.fetch(state.leases, profile_id) do
      {:ok, lease} -> {:reply, {:ok, lease}, state}
      :error -> {:reply, :error, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, state.leases |> Map.values() |> Enum.sort_by(& &1.profile_id), state}
  end

  def handle_call({:run_unleased, profile_id, operation}, _from, state) do
    case Map.fetch(state.leases, profile_id) do
      :error -> {:reply, operation.(), state}
      {:ok, _lease} -> {:reply, {:error, :profile_busy}, state}
    end
  end

  def handle_call({:run_global_launch, operation}, _from, state) do
    if map_size(state.leases) == 0 do
      {:reply, operation.(), state}
    else
      {:reply, {:error, :profile_busy}, state}
    end
  end

  defp reply_transition(state, profile_id, transition) do
    case persist_transition(state, profile_id, transition) do
      {:ok, lease, state} -> {:reply, {:ok, lease}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  defp persist_transition(state, profile_id, {:ok, nil}) do
    case Journal.delete(state.journal, :profile_lease, profile_id) do
      :ok -> {:ok, nil, %{state | leases: Map.delete(state.leases, profile_id)}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp persist_transition(state, profile_id, {:ok, %ProfileLease{} = lease}) do
    case Journal.put(state.journal, :profile_lease, profile_id, lease) do
      :ok -> {:ok, lease, %{state | leases: Map.put(state.leases, profile_id, lease)}}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp persist_transition(state, _profile_id, {:error, reason}), do: {:error, reason, state}

  defp option(opts, key, generator) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> value
      :error -> generator.()
    end
  end

  defp default_mode(:automation), do: :automation
  defp default_mode(:manual), do: :manual
  defp default_mode(_invalid), do: :automation

  defp generate_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.join(
      [
        Integer.to_string(a, 16) |> String.pad_leading(8, "0"),
        Integer.to_string(b, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(c, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(d, 16) |> String.pad_leading(4, "0"),
        Integer.to_string(e, 16) |> String.pad_leading(12, "0")
      ],
      "-"
    )
  end
end
