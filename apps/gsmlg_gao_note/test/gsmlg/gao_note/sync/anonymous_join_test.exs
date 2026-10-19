defmodule GSMLG.GaoNote.Sync.AnonymousJoinTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Store}

  test "a new UUID joins without provisioning and can sync its selected notes" do
    payload = hello()
    assert Repo.get(Peer, payload["node_id"]) == nil
    assert {:ok, %{peer: peer, response: response}} = Sync.join(payload)
    assert peer.id == payload["node_id"]
    assert peer.actor_id == "note_sync:#{peer.id}"
    assert peer.certificate_fingerprint == nil
    assert response["selectors"] == payload["selectors"]
    assert response["node_id"] != peer.id

    {:ok, selected} =
      Compat.save_note(
        %{title: "selected", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, other} =
      Compat.save_note(%{title: "other", content: "body", labels: [["project", "other"]]}, nil)

    assert {:ok, ids} = Sync.inventory(peer)
    assert ids == Enum.sort([selected.id, other.id])
    assert :empty = Sync.checkout(peer, other.id)
    assert Sync.membership(peer.id, other.id) == nil
    assert {:ok, lease} = Sync.checkout(peer, selected.id)
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    assert Sync.pending(peer.id) == []
  end

  test "reconnect preserves pending state and replaces the old session and its leases" do
    payload = hello()
    {:ok, first} = Sync.join(payload)

    {:ok, note} =
      Compat.save_note(
        %{title: "pending", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, lease} = Sync.checkout(first.peer, note.id)
    pending = Sync.pending(first.peer.id)
    membership = Sync.membership(first.peer.id, note.id)
    assert pending != []
    assert Store.get("lease", lease.lease_id, first.peer.id)

    assert {:ok, second} = Sync.join(payload)
    assert second.peer.id == first.peer.id
    assert second.peer.scope_id == first.peer.scope_id
    refute second.peer.session_id == first.peer.session_id
    assert {:error, :obsolete_session} = Sync.checkout(first.peer, note.id)
    assert Store.get("lease", lease.lease_id, first.peer.id) == nil
    assert Sync.pending(second.peer.id) == pending
    assert Sync.membership(second.peer.id, note.id) == membership
    assert {:ok, _} = Sync.checkout(second.peer, note.id)
  end

  test "existing peer metadata is reused without certificate or selector authorization" do
    {:ok, legacy} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("c", 64),
        actor_id: "existing-audit-actor",
        allowed_selectors: ["project=old"]
      })

    assert {:ok, first} = Sync.join(hello(legacy.id))
    assert first.peer.actor_id == legacy.actor_id
    assert first.peer.certificate_fingerprint == nil
    assert first.peer.allowed_selectors == ["project=bear_note"]
    assert {:ok, []} = Sync.inventory(first.peer)

    changed = Map.put(hello(legacy.id), "selectors", ["project=other"])
    assert {:ok, second} = Sync.join(changed)
    refute first.peer.scope_id == second.peer.scope_id
    assert {:error, :obsolete_session} = Sync.inventory(first.peer)
    assert {:ok, []} = Sync.inventory(second.peer)
  end

  test "invalid joins do not create peer records or alter an existing session" do
    payload = hello()

    for invalid <- [
          nil,
          %{},
          Map.put(payload, "node_id", "invalid"),
          Map.put(payload, "node_id", String.upcase(payload["node_id"])),
          Map.put(payload, "protocol_version", 2),
          Map.put(payload, "protocol_version", 1.0),
          Map.put(payload, "max_blob_bytes", 0),
          Map.put(payload, "max_blob_bytes", "1024"),
          Map.put(payload, "selectors", []),
          Map.put(payload, "selectors", ["type=daily", "project=bear_note"]),
          Map.put(payload, "selectors", ["project=bear_note", "project=bear_note"]),
          Map.put(payload, "selectors", ["project~=bear.*"]),
          Map.put(payload, "actor_id", "spoof")
        ] do
      assert {:error, :invalid_join} = Sync.join(invalid)
    end

    assert Repo.all(Peer) == []
    {:ok, joined} = Sync.join(payload)
    assert {:error, :invalid_join} = Sync.join(Map.put(payload, "selectors", []))
    assert Repo.get!(Peer, joined.peer.id).session_id == joined.peer.session_id
    assert {:ok, []} = Sync.inventory(joined.peer)
  end

  test "local node identity and configured blob limits still constrain anonymous joins" do
    {:ok, local} = Sync.local_node_id()
    assert {:error, :invalid_peer} = Sync.join(hello(local))
    assert Repo.get(Peer, local) == nil
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)
    Application.put_env(:gsmlg_gao_note, :note_sync, %{max_blob_bytes: 4096})

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    assert {:ok, joined} = Sync.join(hello())
    assert joined.peer.max_blob_bytes == 4096
    assert joined.response["max_blob_bytes"] == 4096
    assert {:ok, smaller} = Sync.join(Map.put(hello(), "max_blob_bytes", 1024))
    assert smaller.peer.max_blob_bytes == 1024
  end

  defp hello(id \\ Ecto.UUID.generate()) do
    %{
      "protocol_version" => 1,
      "node_id" => id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }
  end
end
