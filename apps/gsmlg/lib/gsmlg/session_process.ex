defmodule GSMLG.SessionProcess do
  use Phoenix.SessionProcess, :process

  @schedule_interval 3000

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)

    state =
      Map.merge(args, %{
        start_at: System.system_time(:second),
        update_at: System.system_time(:second)
      })

    Process.send_after(self(), :schedule, @schedule_interval)
    {:ok, state}
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(:schedule, state) do
    Process.send_after(self(), :schedule, @schedule_interval)
    # IO.inspect({"SessionProcess is alive", label: "SessionProcess", state: state})
    {:noreply, state |> Map.put(:update_at, System.system_time(:second))}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    {:reply, Map.get(state, key), state}
  end

  @impl true
  def handle_cast({:put, key, value}, state) do
    {:noreply, Map.put(state, key, value)}
  end
end
