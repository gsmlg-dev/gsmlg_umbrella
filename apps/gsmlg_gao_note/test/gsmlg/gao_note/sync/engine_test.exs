defmodule GSMLG.GaoNote.Sync.EngineTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias GSMLG.GaoNote.{Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}

  setup do
    {:ok, peer} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("a", 64),
        actor_id: "sync-peer",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, joined} =
      Sync.join(peer, %{
        "protocol_version" => 1,
        "node_id" => peer.id,
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      })

    {:ok, peer: joined.peer}
  end

  test "remote UUID and HLC survive apply, replay, trash, restore and purge", %{peer: peer} do
    event = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, ack} = Sync.apply(peer, event, %{})
    assert ack == Protocol.ack(event)
    assert %Note{id: id, revision: 1, title: "remote"} = Repo.get(Note, event["note_id"])
    assert id == event["note_id"]
    assert {:ok, ^ack} = Sync.apply(peer, event, %{})
    assert Repo.get!(Note, id).revision == 1

    trashed = next(event, 2000, "snapshot", fn s -> Map.put(s, "deleted_at", 2) end)
    assert {:ok, _} = Sync.apply(peer, trashed, %{})
    assert DateTime.to_unix(Repo.get!(Note, id).deleted_at) == 2
    restored = next(trashed, 3000, "snapshot", fn s -> Map.put(s, "deleted_at", nil) end)
    assert {:ok, _} = Sync.apply(peer, restored, %{})
    assert Repo.get!(Note, id).deleted_at == nil
    purge = next(restored, 4000, "purge", fn _ -> nil end)
    assert {:ok, _} = Sync.apply(peer, purge, %{})
    refute Repo.get(Note, id)
    assert {:ok, _} = Sync.apply(peer, restored, %{})
    refute Repo.get(Note, id)
  end

  test "equal versions with different hashes and reused IDs are session errors", %{peer: peer} do
    event = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, event, %{})
    changed = next(event, 1000, "snapshot", fn s -> Map.put(s, "title", "changed") end)
    assert {:error, :version_conflict} = Sync.apply(peer, changed, %{})
    reused = Map.put(changed, "event_id", event["event_id"])
    assert {:error, :event_id_conflict} = Sync.apply(peer, reused, %{})
    assert Repo.get!(Note, event["note_id"]).title == "remote"
  end

  test "an unassociated attach cannot read or overwrite an existing note outside peer scope", %{
    peer: peer
  } do
    {:ok, private} =
      Compat.save_note(
        %{title: "private", content: "private body", labels: [["project", "private"]]},
        nil
      )

    head = Store.get("head", private.id)

    for millis <- [head["version"]["millis"] - 1, head["version"]["millis"] + 1] do
      incoming = event(peer, private.id, millis)
      assert {:error, :unauthorized} = Sync.apply(peer, incoming, %{})
      assert Repo.get!(Note, private.id).content == "private body"
      assert Repo.get!(Note, private.id).revision == private.revision
      assert Sync.membership(peer.id, private.id) == nil
      assert Sync.pending(peer.id) == []
      assert Store.get("received", incoming["event_id"], peer.id) == nil
      assert :empty = Sync.checkout(peer, private.id)
    end
  end

  test "catalog conflict rejects atomically with no receipt or note", %{peer: peer} do
    {:ok, setting} = Compat.define_label_key("project", %{description: "local"})
    event = event(peer, Ecto.UUID.generate(), 1000)
    assert {:error, {:note_rejected, "catalog_conflict"}} = Sync.apply(peer, event, %{})
    refute Repo.get(Note, event["note_id"])
    assert Repo.get!(GSMLG.GaoNote.LabelSetting, setting.id).description == "local"
    assert Sync.pending(peer.id) == []
  end

  test "an inventory fence for an absent UUID cannot authorize a later private local note", %{
    peer: peer
  } do
    id = Ecto.UUID.generate()
    original = event(peer, id, 1000)

    fence =
      Map.merge(original, %{"kind" => "fence", "snapshot" => nil, "control" => hlc(peer.id, 1001)})

    assert {:ok, _} = Sync.apply(peer, fence, %{})
    Repo.insert!(%Note{id: id, title: "private", content: "private body"})

    incoming =
      next(original, System.system_time(:millisecond) + 60_000, "attach", & &1)
      |> Map.merge(%{"generation" => hlc(peer.id, 2000), "control" => hlc(peer.id, 2000)})

    assert {:error, :unauthorized} = Sync.apply(peer, incoming, %{})
    assert Repo.get!(Note, id).content == "private body"
    assert Sync.pending(peer.id) == []
    assert Store.get("received", incoming["event_id"], peer.id) == nil
  end

  test "a previously shared detached note accepts a newer remote association", %{peer: peer} do
    original = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, original, %{})

    detached =
      next(original, 2000, "detach", &Map.put(&1, "labels", []))
      |> Map.put("control", hlc(peer.id, 2001))

    assert {:ok, _} = Sync.apply(peer, detached, %{})
    assert Sync.membership(peer.id, original["note_id"])["attached"] == false

    reentered =
      next(original, 3000, "attach", &Map.put(&1, "content", "reentered"))
      |> Map.merge(%{"generation" => hlc(peer.id, 3001), "control" => hlc(peer.id, 3001)})

    assert {:ok, _} = Sync.apply(peer, reentered, %{})
    assert Repo.get!(Note, original["note_id"]).content == "reentered"
    assert Sync.membership(peer.id, original["note_id"])["attached"]
  end

  test "an unknown fence followed by detach cannot import an unselected note or grant access", %{
    peer: peer
  } do
    original = event(peer, Ecto.UUID.generate(), 1000)

    fence =
      Map.merge(original, %{"kind" => "fence", "snapshot" => nil, "control" => hlc(peer.id, 1001)})

    assert {:ok, _} = Sync.apply(peer, fence, %{})

    detached =
      next(original, 2000, "detach", fn snapshot ->
        [label] = snapshot["labels"]
        Map.put(snapshot, "labels", [Map.put(label, "value", "private")])
      end)
      |> Map.put("control", hlc(peer.id, 2001))

    assert {:ok, _} = Sync.apply(peer, detached, %{})
    refute Repo.get(Note, original["note_id"])
    assert Sync.membership(peer.id, original["note_id"])["authorized"] == false
    assert Sync.pending(peer.id) == []
  end

  test "detach and fence prevent ordinary edits reopening; selector reentry advances generation",
       %{peer: peer} do
    original = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, original, %{})
    detached = next(original, 2000, "detach", & &1) |> Map.put("control", hlc(peer.id, 2001))
    assert {:ok, _} = Sync.apply(peer, detached, %{})
    id = original["note_id"]
    note = Compat.get_note(id)
    assert {:ok, _} = Compat.patch_note(id, note.revision, %{content: "independent"}, nil)
    assert Sync.pending(peer.id) == []
    note = Compat.get_note(id)
    assert {:ok, _} = Compat.patch_note(id, note.revision, %{labels: []}, nil)
    note = Compat.get_note(id)

    assert {:ok, _} =
             Compat.patch_note(id, note.revision, %{labels: [["project", "bear_note"]]}, nil)

    assert [reattach] = Sync.pending(peer.id)
    assert reattach["kind"] == "attach"
    assert Protocol.compare_hlc(reattach["generation"], original["generation"]) == :gt
    assert {:ok, _} = Sync.apply(peer, detached, %{})
    assert Sync.membership(peer.id, id)["attached"]
  end

  test "exact ACK releases only its lease and leaves the newer coalesced pending event", %{
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(%{title: "local", content: "one", labels: [["project", "bear_note"]]}, nil)

    assert {:ok, lease} = Sync.checkout(peer, note.id)
    old_ack = Protocol.ack(lease.event)
    assert {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "two"}, nil)
    assert [new_event] = Sync.pending(peer.id)
    assert new_event["event_id"] != old_ack["event_id"]

    assert {:error, :ack_mismatch} =
             Sync.ack(
               peer,
               Map.put(old_ack, "snapshot_hash", String.duplicate("0", 64)),
               lease.lease_id
             )

    assert :ok = Sync.ack(peer, old_ack, lease.lease_id)
    assert [^new_event] = Sync.pending(peer.id)
    assert :ok = Sync.ack(peer, old_ack, lease.lease_id)
  end

  test "fences never compare or overwrite content versions", %{peer: peer} do
    original = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, original, %{})

    fence =
      original
      |> Map.merge(%{
        "event_id" => Ecto.UUID.generate(),
        "kind" => "fence",
        "snapshot" => nil,
        "snapshot_hash" => String.duplicate("f", 64),
        "control" => hlc(peer.id, 2000)
      })

    assert {:ok, _} = Sync.apply(peer, fence, %{})
    assert Repo.get!(Note, original["note_id"]).title == "remote"
    assert Sync.membership(peer.id, original["note_id"])["attached"] == false
  end

  test "rejections survive reconnect; newer local event and manual retry make work eligible", %{
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(%{title: "local", content: "one", labels: [["project", "bear_note"]]}, nil)

    {:ok, lease} = Sync.checkout(peer, note.id)

    rejection = %{
      "code" => "note_rejected",
      "event_id" => lease.event["event_id"],
      "note_id" => note.id,
      "reason" => "validation_failed"
    }

    assert :ok = Sync.reject(peer, rejection, lease.lease_id)
    assert :empty = Sync.checkout(peer, note.id)
    assert [_] = Sync.pending(peer.id)

    {:ok, joined} =
      Sync.join(peer, %{
        "protocol_version" => 1,
        "node_id" => peer.id,
        "selectors" => peer.selectors,
        "max_blob_bytes" => 536_870_912
      })

    assert :empty = Sync.checkout(joined.peer, note.id)
    assert :ok = Sync.retry(peer.id)
    assert {:ok, _} = Sync.checkout(joined.peer, note.id)

    assert {:error, :obsolete_session} =
             Sync.apply(peer, event(peer, Ecto.UUID.generate(), 1000), %{})
  end

  test "initial same UUID merge returns the historical local winner and preserves a newer remote version",
       %{peer: peer} do
    incoming = event(peer, Ecto.UUID.generate(), 1000)
    time = %{DateTime.from_unix!(5) | microsecond: {0, 6}}

    note =
      Repo.insert!(%Note{
        id: incoming["note_id"],
        title: "native",
        content: "native body",
        created_at: time,
        updated_at: time
      })

    {:ok, setting} = Compat.define_label_key("project", "")

    Repo.insert!(
      Ecto.Changeset.change(%GSMLG.GaoNote.Label{},
        note_id: note.id,
        label_setting_id: setting.id,
        value: "bear_note"
      )
    )

    assert {:ok, processed} = Sync.apply(peer, incoming, %{})
    assert processed == Protocol.ack(incoming)
    assert Repo.get!(Note, note.id).title == "native"
    assert [winner] = Sync.pending(peer.id)
    assert winner["version"]["millis"] == 5000
    assert winner["snapshot"]["updated_at"] == 5
    assert winner["note_id"] == note.id

    newer = next(incoming, 6000, "snapshot", &Map.put(&1, "title", "remote winner"))
    assert {:ok, _} = Sync.apply(peer, newer, %{})
    assert %Note{title: "remote winner", revision: 2} = Repo.get!(Note, note.id)
    assert Store.get("head", note.id)["version"] == newer["version"]
    assert Sync.pending(peer.id) == []
  end

  test "reconnect replays an unconfirmed event and rejects the abandoned lease ACK", %{peer: peer} do
    {:ok, note} =
      Compat.save_note(
        %{title: "offline", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, lost} = Sync.checkout(peer, note.id)

    {:ok, joined} =
      Sync.join(peer, %{
        "protocol_version" => 1,
        "node_id" => peer.id,
        "selectors" => peer.selectors,
        "max_blob_bytes" => 536_870_912
      })

    assert {:error, :ack_mismatch} =
             Sync.ack(joined.peer, Protocol.ack(lost.event), lost.lease_id)

    assert {:ok, replay} = Sync.checkout(joined.peer, note.id)
    assert replay.event == lost.event
    refute replay.lease_id == lost.lease_id
    assert :ok = Sync.ack(joined.peer, Protocol.ack(replay.event), replay.lease_id)
    assert Sync.pending(peer.id) == []
  end

  test "a remote permanent purge propagates to every other active peer", %{peer: peer} do
    {:ok, registered} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("b", 64),
        actor_id: "other-peer",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, other} =
      Sync.join(registered, %{
        "protocol_version" => 1,
        "node_id" => registered.id,
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      })

    original = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, original, %{})
    assert [attach] = Sync.pending(other.peer.id)
    assert attach["kind"] == "attach"

    purge = next(original, 2000, "purge", fn _ -> nil end)
    assert {:ok, _} = Sync.apply(peer, purge, %{})
    assert [propagated] = Sync.pending(other.peer.id)
    assert propagated["kind"] == "purge"
    assert propagated["snapshot"] == nil
    assert propagated["version"] == purge["version"]
    assert :ok = Protocol.validate_event(propagated)
    assert {:ok, lease} = Sync.checkout(other.peer, original["note_id"])
    assert :ok = Sync.ack(other.peer, Protocol.ack(lease.event), lease.lease_id)
    refute Repo.get(Note, original["note_id"])
    assert Sync.membership(other.peer.id, original["note_id"])["event"]["kind"] == "purge"
  end

  test "a selector change survives disconnect before inventory consumes it", %{peer: peer} do
    registered = Repo.get!(GSMLG.GaoNote.Sync.Peer, peer.id)

    Repo.update!(
      Ecto.Changeset.change(registered, allowed_selectors: ["project=bear_note", "type=daily"])
    )

    original = event(peer, Ecto.UUID.generate(), 1000)
    assert {:ok, _} = Sync.apply(peer, original, %{})
    detached = next(original, 2000, "detach", & &1) |> Map.put("control", hlc(peer.id, 2001))
    assert {:ok, _} = Sync.apply(peer, detached, %{})

    payload = %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note", "type=daily"],
      "max_blob_bytes" => 536_870_912
    }

    {:ok, abandoned} = Sync.join(peer, payload)
    assert :ok = Sync.release_session(abandoned.peer)
    {:ok, resumed} = Sync.join(peer, payload)

    assert {:ok, lease} = Sync.checkout(resumed.peer, original["note_id"])
    assert lease.event["kind"] == "attach"
    assert Protocol.compare_hlc(lease.event["generation"], detached["generation"]) == :gt
    assert :ok = Sync.ack(resumed.peer, Protocol.ack(lease.event), lease.lease_id)

    closure =
      Map.merge(lease.event, %{
        "event_id" => Ecto.UUID.generate(),
        "kind" => "detach",
        "control" => hlc(peer.id, lease.event["control"]["millis"] + 1)
      })

    assert {:ok, _} = Sync.apply(resumed.peer, closure, %{})
    assert {:ok, closed} = Sync.checkout(resumed.peer, original["note_id"])
    assert closed.event["kind"] == "fence"
    assert Sync.membership(peer.id, original["note_id"])["attached"] == false
  end

  defp event(peer, id, millis) do
    snapshot = %{
      "title" => "remote",
      "content" => "# remote",
      "created_at" => 1,
      "updated_at" => 1,
      "deleted_at" => nil,
      "labels" => [
        %{"key" => "project", "value" => "bear_note", "description" => "", "value_type" => "text"}
      ],
      "attachments" => []
    }

    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => id,
      "generation" => hlc(peer.id, 500),
      "control" => hlc(peer.id, 500),
      "version" => hlc(peer.id, millis),
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    }
  end

  defp next(event, millis, kind, update) do
    snapshot = update.(event["snapshot"])

    event
    |> Map.merge(%{
      "event_id" => Ecto.UUID.generate(),
      "version" => hlc(event["version"]["node_id"], millis),
      "kind" => kind,
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    })
  end

  defp hlc(node_id, millis), do: %{"millis" => millis, "counter" => 0, "node_id" => node_id}
end
