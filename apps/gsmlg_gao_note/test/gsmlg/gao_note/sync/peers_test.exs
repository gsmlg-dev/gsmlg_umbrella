defmodule GSMLG.GaoNote.Sync.PeersTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote.{Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Store}

  setup do
    {:ok, peer} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("c", 64),
        actor_id: "provisioned-actor",
        allowed_selectors: ["project=bear_note", "type=daily"]
      })

    {:ok, peer: peer}
  end

  test "certificate binding comes from provisioned identity and node stays durable", %{peer: peer} do
    assert {:ok, ^peer} = Sync.authenticate_peer(peer.certificate_fingerprint)
    assert {:error, :unauthorized} = Sync.authenticate_peer(String.duplicate("d", 64))
    assert {:error, :unauthorized} = Sync.authenticate_peer("invalid")
    {:ok, node} = Sync.local_node_id()
    assert {:ok, ^node} = Sync.local_node_id()
    refute node == peer.id
    assert {:ok, %{peer: joined, response: response}} = Sync.join(peer, payload(peer))
    assert joined.actor_id == "provisioned-actor"
    assert response["node_id"] == node
    assert response["selectors"] == ["project=bear_note"]
  end

  test "certificate rotation rejects joins from the cached old socket identity", %{peer: peer} do
    fingerprint = String.duplicate("d", 64)
    Repo.update!(Ecto.Changeset.change(peer, certificate_fingerprint: fingerprint))

    assert {:error, :unauthorized} = Sync.authenticate_peer(peer.certificate_fingerprint)
    assert {:error, :unauthorized} = Sync.join(peer, payload(peer))
    assert {:ok, rotated} = Sync.authenticate_peer(fingerprint)
    assert {:ok, _} = Sync.join(rotated, payload(rotated))
  end

  test "certificate rotation rejects current session operations and preserves pending work", %{
    peer: peer
  } do
    {:ok, joined} = Sync.join(peer, payload(peer))

    {:ok, note} =
      Compat.save_note(
        %{title: "rotation", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, lease} = Sync.checkout(joined.peer, note.id)
    [pending] = Sync.pending(peer.id)

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Peer, peer.id),
        certificate_fingerprint: String.duplicate("d", 64)
      )
    )

    assert Repo.get!(Peer, peer.id).session_id == joined.peer.session_id
    assert {:error, :unauthorized} = Sync.inventory(joined.peer)
    assert {:error, :unauthorized} = Sync.pending_ids(joined.peer)
    assert {:error, :unauthorized} = Sync.checkout(joined.peer, note.id)

    assert {:error, :unauthorized} =
             Sync.ack(joined.peer, Protocol.ack(lease.event), lease.lease_id)

    assert Store.get("lease", lease.lease_id, peer.id)
    assert [^pending] = Sync.pending(peer.id)
    assert Repo.get!(Note, note.id).title == "rotation"
  end

  test "join enforces exact authorized sorted unique nonempty rules and identity", %{peer: peer} do
    for bad <- [
          Map.put(payload(peer), "node_id", Ecto.UUID.generate()),
          Map.put(payload(peer), "protocol_version", 2),
          Map.put(payload(peer), "max_blob_bytes", 0),
          Map.put(payload(peer), "selectors", []),
          Map.put(payload(peer), "selectors", ["project=other"]),
          Map.put(payload(peer), "selectors", ["type=daily", "project=bear_note"]),
          Map.put(payload(peer), "selectors", ["project=bear_note", "project=bear_note"]),
          Map.put(payload(peer), "user_id", "forged-actor")
        ] do
      assert {:error, :unauthorized} = Sync.join(peer, bad)
    end

    assert Repo.get!(Peer, peer.id).selectors == []
  end

  test "unsupported regex cannot be provisioned or joined from a legacy authorization", %{
    peer: peer
  } do
    for selector <- [
          "project~=[a~~a]",
          "project~=[a--a]",
          "project~=[[:alpha:]]",
          "project~=\\w+",
          "project~=(?i)bear",
          "project~=bear.*"
        ] do
      assert {:error, :invalid_peer} =
               Sync.register_peer(%{
                 node_id: Ecto.UUID.generate(),
                 certificate_fingerprint: Protocol.sha256(selector),
                 actor_id: "regex-peer",
                 allowed_selectors: [selector]
               })

      legacy = Repo.update!(Ecto.Changeset.change(peer, allowed_selectors: [selector]))

      assert {:error, :unauthorized} =
               Sync.join(legacy, Map.put(payload(legacy), "selectors", [selector]))

      assert {:error, :unauthorized} = Sync.select(legacy.id, [selector])
    end

    assert Repo.get!(Peer, peer.id).selectors == []
  end

  test "portable regex retains typed AND conditions and selector OR union", %{peer: peer} do
    selectors = ["priority>=2 & project~=^bear_[a-z]ote$", "type=daily"]
    peer = Repo.update!(Ecto.Changeset.change(peer, allowed_selectors: selectors))
    assert {:ok, joined} = Sync.join(peer, Map.put(payload(peer), "selectors", selectors))

    snapshot = fn project, priority, type ->
      %{
        "labels" => [
          %{"key" => "project", "value" => project, "value_type" => "text"},
          %{"key" => "priority", "value" => priority, "value_type" => "number"},
          %{"key" => "type", "value" => type, "value_type" => "text"}
        ]
      }
    end

    assert GSMLG.GaoNote.Sync.Peers.matches?(
             snapshot.("BEAR_NOTE", "2", "other"),
             joined.peer.selectors
           )

    refute GSMLG.GaoNote.Sync.Peers.matches?(
             snapshot.("bear_note", "1", "other"),
             joined.peer.selectors
           )

    refute GSMLG.GaoNote.Sync.Peers.matches?(
             snapshot.("bear_todo", "2", "other"),
             joined.peer.selectors
           )

    assert GSMLG.GaoNote.Sync.Peers.matches?(
             snapshot.("other", "1", "daily"),
             joined.peer.selectors
           )
  end

  test "new sessions reject old writes and cannot release their replacement's lease", %{
    peer: peer
  } do
    {:ok, first} = Sync.join(peer, payload(peer))
    {:ok, second} = Sync.join(peer, payload(peer))
    assert first.peer.session_id != second.peer.session_id
    assert {:error, :obsolete_session} = Sync.inventory(first.peer)
    assert {:ok, []} = Sync.inventory(second.peer)
    assert :ok = Sync.release_session(first.peer)
    assert {:ok, []} = Sync.pending_ids(second.peer)
  end

  test "historical seeding is incremental after join and preserves old timestamps", %{peer: peer} do
    old = DateTime.from_unix!(1_600_000_000) |> DateTime.truncate(:second)
    old = %{old | microsecond: {0, 6}}

    note =
      Repo.insert!(%Note{
        title: "historic",
        content: "historic",
        created_at: old,
        updated_at: old
      })

    {:ok, setting} = GSMLG.GaoNote.Compat.define_label_key("project", "")

    Repo.insert!(
      Ecto.Changeset.change(%GSMLG.GaoNote.Label{},
        note_id: note.id,
        label_setting_id: setting.id,
        value: "bear_note"
      )
    )

    assert {:ok, joined} = Sync.join(peer, payload(peer))
    assert Sync.membership(peer.id, note.id) == nil
    assert {:ok, [id]} = Sync.inventory(joined.peer)
    assert id == note.id
    assert {:ok, lease} = Sync.checkout(joined.peer, id)
    assert lease.event["version"]["millis"] == 1_600_000_000_000
    assert lease.event["snapshot"]["updated_at"] == 1_600_000_000
    assert Protocol.compare_hlc(lease.event["control"], lease.event["generation"]) == :eq
    assert :ok = Sync.ack(joined.peer, Protocol.ack(lease.event), lease.lease_id)
    assert Sync.pending(peer.id) == []
    assert Sync.membership(peer.id, note.id)["event"]["kind"] == "snapshot"
  end

  test "durable clock observes a remote future and advances local counters", %{peer: peer} do
    future = %{
      "millis" => System.system_time(:millisecond) + 60_000,
      "counter" => 4,
      "node_id" => peer.id
    }

    assert {:ok, one} = Store.transaction(fn -> Store.tick(future) end)
    assert one["millis"] == future["millis"]
    assert one["counter"] == 5
    assert {:ok, two} = Store.transaction(fn -> Store.tick() end)
    assert two["millis"] == one["millis"]
    assert two["counter"] == 6
    assert {:ok, node} = Sync.local_node_id()
    assert two["node_id"] == node
  end

  test "changing selected rules invalidates the open session and its read leases", %{peer: peer} do
    {:ok, joined} = Sync.join(peer, payload(peer))

    {:ok, note} =
      Compat.save_note(
        %{title: "selected", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, lease} = Sync.checkout(joined.peer, note.id)

    assert {:ok, _} = Sync.select(peer.id, ["type=daily"])
    assert {:error, :obsolete_session} = Sync.inventory(joined.peer)
    assert Store.get("lease", lease.lease_id, peer.id) == nil
    assert [detached] = Sync.pending(peer.id)
    assert detached["kind"] == "detach"
    assert detached["version"] == lease.event["version"]
    assert Repo.get!(Note, note.id).content == "body"
  end

  test "revocation disconnects the peer and preserves pending notes", %{peer: peer} do
    {:ok, joined} = Sync.join(peer, payload(peer))

    {:ok, note} =
      Compat.save_note(
        %{title: "revoked", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, lease} = Sync.checkout(joined.peer, note.id)
    [pending] = Sync.pending(peer.id)
    :ok = Phoenix.PubSub.subscribe(GSMLG.PubSub, "note_sync:#{peer.id}")

    assert :ok = Sync.revoke_peer(peer.id)
    assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    assert {:error, :unauthorized} = Sync.authenticate_peer(peer.certificate_fingerprint)
    assert {:error, :unauthorized} = Sync.join(peer, payload(peer))
    assert {:error, :obsolete_session} = Sync.checkout(joined.peer, note.id)
    assert Store.get("lease", lease.lease_id, peer.id) == nil
    assert [^pending] = Sync.pending(peer.id)
    assert Repo.get!(Note, note.id).title == "revoked"
  end

  test "every session operation rechecks current selector authorization", %{peer: peer} do
    {:ok, joined} = Sync.join(peer, payload(peer))
    Repo.update!(Ecto.Changeset.change(peer, allowed_selectors: ["type=daily"]))
    assert {:error, :unauthorized} = Sync.inventory(joined.peer)
  end

  test "remote clock overflow rolls back without corrupting the durable clock", %{peer: peer} do
    assert {:ok, before} = Store.transaction(fn -> Store.node() end)

    extreme = %{
      "millis" => System.system_time(:millisecond) + 60_000,
      "counter" => 18_446_744_073_709_551_615,
      "node_id" => peer.id
    }

    assert {:error, :clock_overflow} = Store.transaction(fn -> Store.tick(extreme) end)
    assert {:ok, ^before} = Store.transaction(fn -> Store.node() end)
  end

  defp payload(peer),
    do: %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 1024
    }
end
