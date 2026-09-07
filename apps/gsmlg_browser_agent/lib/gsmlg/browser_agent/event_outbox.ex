defmodule GSMLG.BrowserAgent.EventOutbox do
  @moduledoc "Persistent at-least-once event outbox with cumulative acknowledgements."

  alias GSMLG.BrowserAgent.Journal

  def append(journal \\ Journal, execution_id, event)
      when is_binary(execution_id) and is_map(event) do
    Journal.append_event(journal, execution_id, event)
  end

  def ack(journal \\ Journal, execution_id, sequence)
      when is_binary(execution_id) and is_integer(sequence) and sequence >= 0 do
    Journal.ack_events(journal, execution_id, sequence)
  end

  def cleanup_execution(journal \\ Journal, execution_id) when is_binary(execution_id) do
    Journal.cleanup_event_execution(journal, execution_id)
  end

  def unacked(journal \\ Journal, execution_id) when is_binary(execution_id) do
    journal
    |> Journal.list(:event_outbox)
    |> Enum.flat_map(fn
      {{^execution_id, _sequence}, event} -> [event]
      _other -> []
    end)
    |> Enum.sort_by(& &1["sequence"])
  end
end
