defmodule GSMLG.GaoNote.Sync.ApplyTelemetryTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.Sync.ApplyTelemetry

  test "phase failures expose only bounded identifiers and status, never exception contents" do
    owner = self()
    handler = {__MODULE__, make_ref()}
    prefix = [:gsmlg, :gao_note, :sync, :apply]

    :ok =
      :telemetry.attach_many(
        handler,
        [prefix ++ [:start], prefix ++ [:stop]],
        fn name, measurements, metadata, _ ->
          if self() == owner, do: send(owner, {:phase, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    peer = %{id: Ecto.UUID.generate()}

    event = %{
      "note_id" => "private filename",
      "event_id" => "secret credentials",
      "title" => "private note"
    }

    assert_raise ArgumentError, "private path and upstream response", fn ->
      ApplyTelemetry.phase(peer, event, :prepare, fn ->
        raise ArgumentError, "private path and upstream response"
      end)
    end

    metadata = %{peer_id: peer.id, note_id: nil, event_id: nil, phase: :prepare}

    assert_receive {:phase, [:gsmlg, :gao_note, :sync, :apply, :start], %{monotonic_time: _},
                    ^metadata}

    assert_receive {:phase, [:gsmlg, :gao_note, :sync, :apply, :stop], %{duration: duration},
                    stop_metadata}

    assert duration >= 0
    assert stop_metadata == Map.put(metadata, :result, :error)
  end
end
