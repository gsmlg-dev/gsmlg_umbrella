defmodule GSMLG.Web.AgentNotePDFPool do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def acquire, do: GenServer.call(__MODULE__, {:acquire, self()})
  def release(ref), do: GenServer.call(__MODULE__, {:release, ref})
  def init(_), do: {:ok, %{}}

  def handle_call({:acquire, owner}, _from, leases) when map_size(leases) < 2 do
    ref = Process.monitor(owner)
    {:reply, {:ok, ref}, Map.put(leases, ref, owner)}
  end

  def handle_call({:acquire, _}, _from, leases), do: {:reply, {:error, :busy}, leases}

  def handle_call({:release, ref}, _from, leases) do
    Process.demonitor(ref, [:flush])
    {:reply, :ok, Map.delete(leases, ref)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, leases), do: {:noreply, Map.delete(leases, ref)}
end
