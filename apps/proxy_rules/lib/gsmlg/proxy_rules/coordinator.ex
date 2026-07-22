defmodule GSMLG.ProxyRules.Coordinator do
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def refresh do
    try do
      GenServer.call(__MODULE__, :refresh)
    catch
      :exit, _reason -> {:error, :not_available}
    end
  end

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_call(:refresh, _from, state), do: {:reply, {:error, :not_available}, state}
end
