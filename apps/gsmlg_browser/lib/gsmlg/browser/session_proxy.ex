defmodule GSMLG.Browser.SessionProxy do
  @moduledoc false
  use GenServer, restart: :transient

  alias GSMLG.Browser.{CommanderBridge, Node, Session}
  alias GSMLG.Repo

  def call(%Session{} = session, operation, payload, idempotency_key) do
    with {:ok, pid} <- ensure_started(session.id) do
      GenServer.call(pid, {:rpc, session, operation, payload, idempotency_key}, 35_000)
    end
  end

  def start_link(session_id),
    do: GenServer.start_link(__MODULE__, session_id, name: via(session_id))

  @impl true
  def init(session_id), do: {:ok, session_id}

  @impl true
  def handle_call({:rpc, session, operation, payload, idempotency_key}, _from, state) do
    node = Repo.get!(Node, session.node_id)
    deadline = DateTime.add(DateTime.utc_now(), 30, :second)
    {:reply, CommanderBridge.call(node, operation, payload, idempotency_key, deadline), state}
  end

  defp ensure_started(session_id) do
    case Registry.lookup(GSMLG.Browser.SessionRegistry, session_id) do
      [{pid, _value}] ->
        {:ok, pid}

      [] ->
        DynamicSupervisor.start_child(GSMLG.Browser.SessionSupervisor, {__MODULE__, session_id})
    end
  end

  defp via(session_id), do: {:via, Registry, {GSMLG.Browser.SessionRegistry, session_id}}
end
