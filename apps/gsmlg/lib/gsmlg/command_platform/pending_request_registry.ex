defmodule GSMLG.CommandPlatform.PendingRequestRegistry do
  @moduledoc "Tracks central RPC callers independently from live Commander connections."

  use GenServer

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def register(server \\ __MODULE__, request_id, caller, timeout_ms) do
    GenServer.call(server, {:register, request_id, caller, timeout_ms, %{}})
  end

  def register_request(server \\ __MODULE__, agent_id, request, wire, caller, timeout_ms) do
    GenServer.call(
      server,
      {:register, request.request_id, caller, timeout_ms,
       %{agent_id: agent_id, request: request, wire: wire}}
    )
  end

  def complete(server \\ __MODULE__, request_id, result) do
    GenServer.call(server, {:complete, request_id, result})
  end

  def cancel(server \\ __MODULE__, request_id), do: GenServer.call(server, {:cancel, request_id})

  def pending_for_agent(server \\ __MODULE__, agent_id) do
    GenServer.call(server, {:pending_for_agent, agent_id})
  end

  @impl true
  def init(_opts), do: {:ok, %{pending: %{}}}

  @impl true
  def handle_call({:register, request_id, caller, timeout_ms, metadata}, _from, state) do
    if Map.has_key?(state.pending, request_id) do
      {:reply, {:error, :already_pending}, state}
    else
      timer = Process.send_after(self(), {:timeout, request_id}, timeout_ms)

      pending =
        Map.put(state.pending, request_id, Map.merge(metadata, %{caller: caller, timer: timer}))

      {:reply, :ok, %{state | pending: pending}}
    end
  end

  def handle_call({:pending_for_agent, agent_id}, _from, state) do
    pending =
      state.pending
      |> Map.values()
      |> Enum.filter(&(&1[:agent_id] == agent_id))

    {:reply, pending, state}
  end

  def handle_call({:complete, request_id, result}, _from, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:reply, :ok, state}

      {%{caller: caller, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        send(caller, {:commander_rpc_result, request_id, result})
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  def handle_call({:cancel, request_id}, _from, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:reply, :ok, state}

      {%{timer: timer}, pending} ->
        Process.cancel_timer(timer)
        {:reply, :ok, %{state | pending: pending}}
    end
  end

  @impl true
  def handle_info({:timeout, request_id}, state) do
    case Map.pop(state.pending, request_id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{caller: caller}, pending} ->
        send(caller, {:commander_rpc_timeout, request_id})
        {:noreply, %{state | pending: pending}}
    end
  end
end
