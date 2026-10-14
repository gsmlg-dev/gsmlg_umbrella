defmodule GSMLG.GaoNote.SyncFixtures do
  @moduledoc false
  alias GSMLG.GaoNote.Sync.Protocol

  def event do
    vector = vectors() |> Enum.at(1)

    snapshot =
      put_in(
        vector["snapshot"],
        ["content"],
        String.replace(vector["snapshot"]["content"], <<0>>, "")
      )

    clock = %{
      "millis" => 1_791_676_800_000,
      "counter" => 0,
      "node_id" => "aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa"
    }

    %{
      "event_id" => "bbbbbbbb-bbbb-4bbb-bbbb-bbbbbbbbbbbb",
      "note_id" => "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
      "generation" => clock,
      "control" => clock,
      "version" => clock,
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    }
  end

  def vectors do
    Path.expand("../fixtures/sync/hash-vectors-v1.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("vectors")
  end
end
