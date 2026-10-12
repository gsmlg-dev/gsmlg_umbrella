defmodule GSMLG.GaoNote.Sync.ProtocolTest do
  use ExUnit.Case, async: true
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

  defp vectors do
    Path.expand("../../../fixtures/sync/hash-vectors-v1.json", __DIR__)
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("vectors")
  end

  test "independent Unicode and null hash vectors match exactly" do
    for vector <- vectors() do
      assert Protocol.canonical_json(vector["snapshot"]) == vector["canonical_utf8"]
      assert Protocol.snapshot_hash(vector["snapshot"]) == vector["sha256"]
    end
  end

  test "accepts complete descriptor and ACK excludes only snapshot" do
    event = event()
    assert :ok = Protocol.validate_event(event)
    assert Protocol.ack(event) == Map.delete(event, "snapshot")
  end

  test "rejects extra fields, missing fields, hash mismatch and unsorted arrays" do
    event = event()

    for bad <- [
          Map.put(event, "actor_id", "spoof"),
          Map.delete(event, "control"),
          Map.put(event, "snapshot_hash", String.duplicate("0", 64)),
          put_in(event, ["snapshot", "labels"], Enum.reverse(event["snapshot"]["labels"]))
        ] do
      assert {:error, :validation_failed} = Protocol.validate_event(bad)
    end
  end

  test "rejects duplicate IDs and unsafe paths even with a matching hash" do
    for path <- [
          "/abs",
          "../escape",
          "a/../b",
          "./file",
          "a//b",
          "https://host/a",
          "a\\b",
          "a/",
          "a\u0000b"
        ] do
      bad = put_in(event(), ["snapshot", "attachments", Access.at(0), "path"], path)
      bad = Map.put(bad, "snapshot_hash", Protocol.snapshot_hash(bad["snapshot"]))
      assert {:error, :validation_failed} = Protocol.validate_event(bad)
    end
  end

  test "rejects invalid typed values NUL business text and closure clocks" do
    for {path, value} <- [
          {["generation", "millis"], -1},
          {["snapshot", "title"], "  "},
          {["snapshot", "content"], "a" <> <<0>>},
          {["snapshot", "labels", Access.at(0), "value"], "not a number"},
          {["snapshot", "labels", Access.at(1), "key"], "project=spoof"}
        ] do
      bad = put_in(event(), path, value)
      bad = Map.put(bad, "snapshot_hash", Protocol.snapshot_hash(bad["snapshot"]))
      assert {:error, :validation_failed} = Protocol.validate_event(bad)
    end

    assert {:error, :validation_failed} =
             Protocol.validate_event(Map.put(event(), "kind", "detach"))

    assert {:error, :validation_failed} =
             Protocol.validate_event(
               event()
               |> Map.put("kind", "fence")
               |> Map.put("snapshot", nil)
             )
  end

  test "fences retain closing hashes while purge requires null hash" do
    event = event() |> Map.put("snapshot", nil) |> put_in(["control", "counter"], 1)
    assert :ok = Protocol.validate_event(Map.put(event, "kind", "fence"))
    assert {:error, :validation_failed} = Protocol.validate_event(Map.put(event, "kind", "purge"))

    assert :ok =
             Protocol.validate_event(
               event
               |> Map.put("kind", "purge")
               |> Map.put("snapshot_hash", Protocol.snapshot_hash(nil))
             )
  end

  test "HLC compares timestamp counter and node lexicographically" do
    clock = event()["version"]
    assert :eq = Protocol.compare_hlc(clock, clock)
    assert :lt = Protocol.compare_hlc(clock, Map.put(clock, "counter", 1))

    assert :gt =
             Protocol.compare_hlc(
               clock,
               Map.put(clock, "node_id", "00000000-0000-4000-8000-000000000000")
             )
  end
end
