defmodule GSMLG.Commander.RequestDedup do
  @moduledoc """
  Serialized request and idempotency-key deduplication for remote RPC handling.

  This process is outside the socket subtree, so a reconnect cannot discard the
  outcome needed to safely replay an at-least-once request.
  """

  use GenServer

  alias GSMLG.Commander.Protocol.RPCRequest

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def claim(server \\ __MODULE__, %RPCRequest{} = request) do
    GenServer.call(server, {:claim, request})
  end

  def complete(server \\ __MODULE__, %RPCRequest{} = request, result) do
    GenServer.call(server, {:complete, request, result})
  end

  @doc false
  def lookup(server \\ __MODULE__, %RPCRequest{} = request) do
    GenServer.call(server, {:lookup, request})
  end

  def execution_capability(server \\ __MODULE__, remote_execution_id) do
    GenServer.call(server, {:execution_capability, remote_execution_id})
  end

  @doc false
  def fingerprint(%RPCRequest{} = request) do
    request
    |> Map.take([:capability, :capability_version, :operation, :idempotency_key, :payload])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       requests: %{},
       idempotency: %{},
       executions: %{},
       ttl_ms: Keyword.get(opts, :ttl_ms, :timer.hours(24)),
       max_entries: Keyword.get(opts, :max_entries, 10_000)
     }}
  end

  @impl true
  def handle_call({:claim, request}, _from, state) do
    state = prune(state)
    fingerprint = fingerprint(request)

    case claim_result(state, request, fingerprint) do
      :new ->
        case make_room(state) do
          {:ok, state} ->
            now = System.monotonic_time(:millisecond)

            entry = %{
              request_id: request.request_id,
              idempotency_key: request.idempotency_key,
              fingerprint: fingerprint,
              capability: request.capability,
              inserted_at: now,
              expires_at: now + state.ttl_ms,
              status: :running,
              result: nil
            }

            state = put_entry(state, entry)
            {:reply, :execute, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      result ->
        {:reply, result, state}
    end
  end

  def handle_call({:complete, request, result}, _from, state) do
    state = prune(state)
    request_fingerprint = fingerprint(request)

    case Map.get(state.requests, request.request_id) do
      %{fingerprint: ^request_fingerprint} = entry ->
        completed = %{entry | status: :completed, result: result}

        state = put_entry(state, completed) |> bind_execution(completed, result)

        {:reply, :ok, state}

      _missing_or_changed ->
        {:reply, {:error, :request_not_claimed}, state}
    end
  end

  def handle_call({:lookup, request}, _from, state) do
    state = prune(state)
    {:reply, claim_result(state, request, fingerprint(request)), state}
  end

  def handle_call({:execution_capability, remote_execution_id}, _from, state) do
    state = prune(state)

    case Map.get(state.executions, remote_execution_id) do
      %{capability: capability} -> {:reply, {:ok, capability}, state}
      nil -> {:reply, {:error, :unknown_execution}, state}
    end
  end

  defp claim_result(state, request, fingerprint) do
    case Map.get(state.requests, request.request_id) do
      %{fingerprint: existing} when existing != fingerprint ->
        {:error, :request_payload_collision}

      %{status: :running, request_id: request_id} ->
        {:in_progress, request_id}

      %{status: :completed, result: result} ->
        {:replay, result}

      nil ->
        claim_idempotency(state, request, fingerprint)
    end
  end

  defp claim_idempotency(state, request, fingerprint) do
    case Map.get(state.idempotency, request.idempotency_key) do
      %{fingerprint: existing} when existing != fingerprint ->
        {:error, :idempotency_payload_collision}

      %{status: :running, request_id: request_id} ->
        {:in_progress, request_id}

      %{status: :completed, result: result} ->
        {:replay, result}

      nil ->
        :new
    end
  end

  defp put_entry(state, entry) do
    %{
      state
      | requests: Map.put(state.requests, entry.request_id, entry),
        idempotency: Map.put(state.idempotency, entry.idempotency_key, entry)
    }
  end

  defp bind_execution(state, entry, %{__struct__: GSMLG.Commander.Protocol.RPCAccepted} = result) do
    execution = %{
      capability: entry.capability,
      inserted_at: entry.inserted_at,
      expires_at: entry.expires_at
    }

    executions =
      make_execution_room(state.executions, result.remote_execution_id, state.max_entries)

    %{state | executions: Map.put(executions, result.remote_execution_id, execution)}
  end

  defp bind_execution(state, _entry, _result), do: state

  defp prune(state) do
    now = System.monotonic_time(:millisecond)

    requests =
      Map.filter(state.requests, fn {_request_id, entry} -> entry.expires_at > now end)

    executions =
      Map.filter(state.executions, fn {_execution_id, entry} -> entry.expires_at > now end)

    rebuild_indexes(%{state | requests: requests, executions: executions})
  end

  defp make_room(state) when map_size(state.requests) < state.max_entries, do: {:ok, state}

  defp make_room(state) do
    completed = Enum.filter(state.requests, fn {_id, entry} -> entry.status == :completed end)

    case Enum.min_by(completed, fn {_id, entry} -> entry.inserted_at end, fn -> nil end) do
      {request_id, _entry} ->
        {:ok, rebuild_indexes(%{state | requests: Map.delete(state.requests, request_id)})}

      nil ->
        {:error, :dedup_capacity_exceeded}
    end
  end

  defp rebuild_indexes(state) do
    idempotency =
      Map.new(state.requests, fn {_request_id, entry} -> {entry.idempotency_key, entry} end)

    %{state | idempotency: idempotency}
  end

  defp make_execution_room(executions, execution_id, max_entries)
       when map_size(executions) < max_entries or is_map_key(executions, execution_id),
       do: executions

  defp make_execution_room(executions, _execution_id, _max_entries) do
    {oldest_id, _entry} = Enum.min_by(executions, fn {_id, entry} -> entry.inserted_at end)
    Map.delete(executions, oldest_id)
  end
end
