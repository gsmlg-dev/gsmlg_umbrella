defmodule GSMLG.BrowserAgent.EventDelivery do
  @moduledoc "Durable ordered workflow-event delivery independent of workflow runners."

  use GenServer

  alias GSMLG.BrowserAgent.Journal
  alias GSMLG.Commander.Connection
  alias GSMLG.Commander.Protocol.{EventAck, JobEvent}

  @default_interval_ms 1_000

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def deliver_now(server \\ __MODULE__), do: GenServer.call(server, :deliver_now, :infinity)

  def ack(server \\ __MODULE__, %EventAck{} = ack),
    do: GenServer.call(server, {:ack, ack})

  @impl true
  def init(opts) do
    state = %{
      journal: Keyword.get(opts, :journal, Journal),
      connection: Keyword.get(opts, :connection, Connection),
      sender: Keyword.get(opts, :sender, &send_event/2),
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      timer: nil
    }

    {:ok, schedule(state)}
  end

  @impl true
  def handle_call(:deliver_now, _from, state), do: {:reply, deliver(state), state}

  def handle_call({:ack, %EventAck{} = ack}, _from, state) do
    result =
      Journal.ack_events(
        state.journal,
        ack.remote_execution_id,
        ack.highest_contiguous_sequence
      )

    {:reply, result, state}
  end

  @impl true
  def handle_info(:deliver, state) do
    _ = deliver(state)
    {:noreply, schedule(%{state | timer: nil})}
  end

  def handle_info({:event_ack, %EventAck{} = ack}, state) do
    _ =
      Journal.ack_events(state.journal, ack.remote_execution_id, ack.highest_contiguous_sequence)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp deliver(state) do
    state.journal
    |> Journal.event_execution_ids()
    |> Enum.reduce_while(:ok, fn execution_id, :ok ->
      case deliver_execution(state, execution_id) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  catch
    :exit, _reason -> {:error, :event_journal_unavailable}
  end

  defp deliver_execution(state, execution_id) do
    state.journal
    |> Journal.event_unacked(execution_id)
    |> Enum.reduce_while(:ok, fn wire, :ok ->
      with {:ok, event} <- JobEvent.decode(wire),
           :ok <- normalize_send(state.sender.(event, state.connection)),
           :ok <- Journal.mark_event_emitted(state.journal, execution_id, event.sequence) do
        {:cont, :ok}
      else
        {:error, _reason} = error -> {:halt, error}
        _invalid -> {:halt, {:error, :event_delivery_failed}}
      end
    end)
  end

  defp normalize_send(:ok), do: :ok
  defp normalize_send({:ok, _result}), do: :ok
  defp normalize_send({:error, _reason} = error), do: error
  defp normalize_send(_invalid), do: {:error, :event_delivery_failed}

  defp send_event(event, connection), do: Connection.push(event, connection)

  defp schedule(%{timer: nil, interval_ms: interval_ms} = state)
       when is_integer(interval_ms) and interval_ms > 0 do
    %{state | timer: Process.send_after(self(), :deliver, interval_ms)}
  end

  defp schedule(state), do: state
end
