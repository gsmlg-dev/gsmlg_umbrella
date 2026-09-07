defmodule GSMLG.Commander.CapabilityRegistry do
  @moduledoc """
  Process-local registry of validated Commander capability descriptors and handlers.

  The registry is deliberately a sibling of the transport connection so registered
  capabilities survive socket reconnects and certificate rotation.
  """

  use GenServer

  alias GSMLG.Commander.Protocol.Envelope

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def register(server \\ __MODULE__, descriptor, handler) do
    with {:ok, _wire} <- Envelope.encode(descriptor) do
      GenServer.call(server, {:register, descriptor, handler})
    end
  end

  def unregister(server \\ __MODULE__, capability_id) do
    GenServer.call(server, {:unregister, capability_id})
  end

  def fetch(server \\ __MODULE__, capability_id) do
    GenServer.call(server, {:fetch, capability_id})
  end

  def list(server \\ __MODULE__) do
    GenServer.call(server, :list)
  end

  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @impl true
  def init(opts) do
    capabilities =
      opts
      |> Keyword.get(:initial_capabilities, [])
      |> Enum.reduce(%{}, fn {descriptor, handler}, capabilities ->
        {:ok, _wire} = Envelope.encode(descriptor)
        Map.put(capabilities, descriptor.id, {descriptor, handler})
      end)

    {:ok, %{capabilities: capabilities, subscribers: %{}}}
  end

  @impl true
  def handle_call({:register, descriptor, handler}, _from, state) do
    capabilities = Map.put(state.capabilities, descriptor.id, {descriptor, handler})
    notify_subscribers(state.subscribers, capabilities)
    {:reply, :ok, %{state | capabilities: capabilities}}
  end

  def handle_call({:unregister, capability_id}, _from, state) do
    capabilities = Map.delete(state.capabilities, capability_id)
    notify_subscribers(state.subscribers, capabilities)
    {:reply, :ok, %{state | capabilities: capabilities}}
  end

  def handle_call({:fetch, capability_id}, _from, state) do
    case Map.fetch(state.capabilities, capability_id) do
      {:ok, capability} -> {:reply, {:ok, capability}, state}
      :error -> {:reply, {:error, :capability_not_registered}, state}
    end
  end

  def handle_call(:list, _from, state) do
    {:reply, sorted_capabilities(state.capabilities), state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    if Map.has_key?(state.subscribers, pid) do
      {:reply, :ok, state}
    else
      ref = Process.monitor(pid)
      {:reply, :ok, %{state | subscribers: Map.put(state.subscribers, pid, ref)}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      case Map.get(state.subscribers, pid) do
        ^ref -> Map.delete(state.subscribers, pid)
        _other -> state.subscribers
      end

    {:noreply, %{state | subscribers: subscribers}}
  end

  defp notify_subscribers(subscribers, capabilities) do
    descriptors = Enum.map(sorted_capabilities(capabilities), &elem(&1, 0))
    Enum.each(Map.keys(subscribers), &send(&1, {:commander_capabilities_changed, descriptors}))
  end

  defp sorted_capabilities(capabilities) do
    capabilities
    |> Map.values()
    |> Enum.sort_by(fn {descriptor, _handler} -> descriptor.id end)
  end
end
