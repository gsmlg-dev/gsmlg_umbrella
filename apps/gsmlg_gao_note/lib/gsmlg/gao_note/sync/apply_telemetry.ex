defmodule GSMLG.GaoNote.Sync.ApplyTelemetry do
  @moduledoc false

  alias GSMLG.GaoNote.Sync.Protocol
  alias GSMLG.Telemetry

  @event [:gsmlg, :gao_note, :sync, :apply]

  def phase(peer, event, phase, work) do
    metadata = %{
      peer_id: peer.id,
      note_id: identifier(event, "note_id"),
      event_id: identifier(event, "event_id"),
      phase: phase
    }

    started = System.monotonic_time()
    Telemetry.info("GaoNote sync apply phase started", metadata: metadata)
    Telemetry.emit(@event ++ [:start], %{monotonic_time: started}, metadata)

    try do
      result = work.()
      status = if match?({:error, _}, result), do: :error, else: :ok
      finished(started, metadata, status)
      result
    catch
      kind, reason ->
        finished(started, metadata, :error)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp finished(started, metadata, result) do
    duration = System.monotonic_time() - started
    metadata = Map.put(metadata, :result, result)

    Telemetry.info("GaoNote sync apply phase finished",
      metadata:
        Map.put(metadata, :duration_ms, System.convert_time_unit(duration, :native, :millisecond))
    )

    Telemetry.emit(@event ++ [:stop], %{duration: duration}, metadata)
  end

  defp identifier(event, key) when is_map(event) do
    value = event[key]
    if Protocol.uuid?(value), do: value
  end

  defp identifier(_, _), do: nil
end
