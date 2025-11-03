defmodule GSMLG.SessionProcess do
  use Phoenix.SessionProcess, :process

  alias GSMLG.SessionProcess.UserReducer

  @impl true
  def init_state(_args) do
    %{}
  end

  @impl true
  def combined_reducers() do
    [UserReducer]
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

  def handle_info(any, state) do
    IO.inspect({"Unhandled info message", any, state})
    {:noreply, state}
  end
end
