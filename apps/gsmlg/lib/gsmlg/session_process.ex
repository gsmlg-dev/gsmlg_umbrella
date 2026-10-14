defmodule GSMLG.SessionProcess do
  use Phoenix.SessionProcess, :process

  alias GSMLG.SessionProcess.{StorageReducer, UserReducer}

  @impl true
  def init_state(_args) do
    Process.flag(:trap_exit, true)
    %{}
  end

  @impl true
  def combined_reducers() do
    [UserReducer, StorageReducer]
  end

  @impl true
  def handle_cast({:storage_load_finished, token}, state) do
    ref = {:storage, token}

    {:noreply,
     %{
       state
       | _async_cancel_fns: Map.delete(state._async_cancel_fns, ref),
         _cancelled_refs: MapSet.delete(state._cancelled_refs, ref)
     }}
  end

  def handle_cast(message, state), do: super(message, state)

  @impl true
  def terminate(_reason, state) do
    Enum.each(state._async_cancel_fns, fn
      {{:storage, _token}, cancel} -> cancel.()
      _other -> :ok
    end)
  end

  @impl true
  def handle_info({:EXIT, _pid, _reason}, state) do
    {:stop, :normal, state}
  end

  def handle_info(
        {:DOWN, _ref, :process, pid, {:shutdown, _reason}},
        %{_redux_subscriptions: redux_subscriptions} = state
      ) do
    redux_subscriptions =
      Enum.filter(redux_subscriptions, fn subscription ->
        cond do
          subscription.pid == pid -> false
          true -> true
        end
      end)

    {:noreply, %{state | _redux_subscriptions: redux_subscriptions}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason} = message, state),
    do: super(message, state)

  def handle_info(any, state) do
    IO.inspect({"Unhandled info message", any, state})
    {:noreply, state}
  end
end
