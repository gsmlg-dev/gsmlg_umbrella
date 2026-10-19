defmodule GSMLG.GaoNote.Sync.ReleaseLeaseTest do
  use GSMLG.GaoNote.DataCase, async: false

  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}

  setup do
    {:ok, registered} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("a", 64),
        actor_id: "sync-peer",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, joined} = join(registered)

    {:ok, note} =
      Compat.save_note(
        %{title: "lease recovery", content: "one", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, peer: joined.peer, note: note}
  end

  test "releasing a failed read removes only its lease and retains the newer pending snapshot", %{
    peer: peer,
    note: note
  } do
    assert {:ok, failed} = Sync.checkout(peer, note.id)
    assert {:ok, concurrent} = Sync.checkout(peer, note.id)
    assert {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "two"}, nil)
    assert [newer_event] = Sync.pending(peer.id)
    assert newer_event["event_id"] != failed.event["event_id"]
    assert {:ok, newer} = Sync.checkout(peer, note.id)
    assert newer.event == newer_event

    concurrent_lease = Store.get("lease", concurrent.lease_id, peer.id)
    newer_lease = Store.get("lease", newer.lease_id, peer.id)
    member = Sync.membership(peer.id, note.id)

    assert :ok = Sync.release_lease(peer, failed.lease_id)
    assert Store.get("lease", failed.lease_id, peer.id) == nil
    assert Store.get("lease", concurrent.lease_id, peer.id) == concurrent_lease
    assert Store.get("lease", newer.lease_id, peer.id) == newer_lease
    assert Store.get("ack", failed.lease_id, peer.id) == nil
    assert Sync.pending(peer.id) == [newer_event]
    assert Sync.membership(peer.id, note.id) == member

    assert :ok = Sync.release_lease(peer, failed.lease_id)
    assert Sync.pending(peer.id) == [newer_event]
    assert :ok = Sync.ack(peer, Protocol.ack(newer.event), newer.lease_id)
    assert Sync.pending(peer.id) == []
    assert Store.get("lease", concurrent.lease_id, peer.id) == concurrent_lease
  end

  test "abandoned-session cleanup cannot release a replacement session's read lease", %{
    peer: peer,
    note: note
  } do
    assert {:ok, abandoned} = Sync.checkout(peer, note.id)
    assert {:ok, replacement} = join(peer)
    assert replacement.peer.session_id != peer.session_id
    assert {:ok, current} = Sync.checkout(replacement.peer, note.id)
    assert current.event == abandoned.event
    current_lease = Store.get("lease", current.lease_id, peer.id)
    pending = Sync.pending(peer.id)

    assert :ok = Sync.release_lease(peer, abandoned.lease_id)
    assert :ok = Sync.release_lease(peer, current.lease_id)
    assert Store.get("lease", current.lease_id, peer.id) == current_lease
    assert Sync.pending(peer.id) == pending
    assert {:ok, ids} = Sync.pending_ids(replacement.peer)
    assert note.id in ids

    assert :ok = Sync.ack(replacement.peer, Protocol.ack(current.event), current.lease_id)
    assert Sync.pending(peer.id) == []
  end

  defp join(peer) do
    Sync.join(peer, %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    })
  end
end
