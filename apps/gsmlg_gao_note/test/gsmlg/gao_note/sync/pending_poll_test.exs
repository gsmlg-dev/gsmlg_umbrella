defmodule GSMLG.GaoNote.Sync.PendingPollTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias GSMLG.GaoNote.{Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Record, Store}
  alias GSMLG.Repo

  setup do
    unboxed(fn ->
      value = Ecto.UUID.generate()

      {:ok, joined} =
        Sync.join(%{
          "protocol_version" => 1,
          "node_id" => Ecto.UUID.generate(),
          "selectors" => ["pending_poll_test=" <> value],
          "max_blob_bytes" => 536_870_912
        })

      {:ok, note} =
        Compat.save_note(
          %{title: "pending", content: "body", labels: [["pending_poll_test", value]]},
          nil
        )

      {:ok, lease} = Sync.checkout(joined.peer, note.id)
      peer = joined.peer

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(
            from(r in Record, where: r.peer_id == ^peer.id or r.note_id == ^note.id)
          )

          Repo.delete_all(from(n in Note, where: n.id == ^note.id))
          Repo.delete_all(from(p in Peer, where: p.id == ^peer.id))
        end)
      end)

      {:ok, peer: peer, note: note, lease: lease}
    end)
  end

  test "an apply holding its peer lock beyond ten seconds cannot block polling or lease renewal",
       %{peer: peer, note: note, lease: lease} do
    unboxed(fn ->
      remote_id = Ecto.UUID.generate()

      event =
        Map.merge(lease.event, %{"event_id" => Ecto.UUID.generate(), "note_id" => remote_id})

      on_exit(fn ->
        unboxed(fn ->
          Repo.delete_all(from(r in Record, where: r.note_id == ^remote_id))
          Repo.delete_all(from(n in Note, where: n.id == ^remote_id))
        end)
      end)

      blocker = hold_lock(fn -> Store.lock("note", remote_id) end)
      apply_task = async(fn -> Sync.apply(peer, event, %{}) end)

      try do
        await_peer_lock(peer.id)
        pending = Sync.pending(peer.id)
        original = Store.get("lease", lease.lease_id, peer.id)
        shortened = System.system_time(:millisecond) + 5_000

        Store.put(
          "lease",
          lease.lease_id,
          Map.put(original, "expires_at", shortened),
          peer.id,
          note.id
        )

        assert_poll(peer, {:ok, :busy})
        first = Store.get("lease", lease.lease_id, peer.id)["expires_at"]
        assert first > shortened + 30_000

        Process.sleep(10_100)
        assert Process.alive?(apply_task.pid)
        assert_poll(peer, {:ok, :busy})
        assert Store.get("lease", lease.lease_id, peer.id)["expires_at"] > first + 9_000
        assert Sync.pending(peer.id) == pending
      after
        release_lock(blocker)
        assert {:ok, {:ok, _ack}} = Task.yield(apply_task, 5_000)
      end

      assert {:ok, ids} = Sync.pending_ids(peer)
      assert note.id in ids
    end)
  end

  test "busy polling still rejects an obsolete session and forged peer identity", %{peer: peer} do
    unboxed(fn ->
      blocker =
        hold_lock(fn ->
          Repo.one!(from(p in Peer, where: p.id == ^peer.id, lock: "FOR UPDATE"))
        end)

      try do
        assert_poll(%{peer | session_id: Ecto.UUID.generate()}, {:error, :obsolete_session})

        assert_poll(
          %{peer | certificate_fingerprint: Protocol.sha256("forged")},
          {:error, :unauthorized}
        )

        assert_poll(
          %{peer | selectors: ["pending_poll_test=forged"]},
          {:error, :obsolete_session}
        )
      after
        release_lock(blocker)
      end

      assert :ok = Sync.revoke_peer(peer.id)
      assert_poll(peer, {:error, :obsolete_session})
    end)
  end

  test "a contended lease is skipped without blocking or resurrecting a deleted lease", %{
    peer: peer,
    note: note,
    lease: lease
  } do
    unboxed(fn ->
      record_id = Store.key("lease", peer.id, lease.lease_id)

      blocker =
        hold_lock(
          fn -> Repo.one!(from(r in Record, where: r.id == ^record_id, lock: "FOR UPDATE")) end,
          fn -> Store.delete("lease", lease.lease_id, peer.id) end
        )

      try do
        assert_poll(peer, {:ok, :busy})
      after
        release_lock(blocker)
      end

      assert {:ok, ids} = Sync.pending_ids(peer)
      assert note.id in ids
      assert Store.get("lease", lease.lease_id, peer.id) == nil
    end)
  end

  test "free polling returns durable IDs and renews only the current session", %{
    peer: peer,
    note: note,
    lease: lease
  } do
    unboxed(fn ->
      current = Store.get("lease", lease.lease_id, peer.id)
      shortened = System.system_time(:millisecond) + 5_000
      current = Map.put(current, "expires_at", shortened)
      Store.put("lease", lease.lease_id, current, peer.id, note.id)

      other_id = Ecto.UUID.generate()
      other = Map.put(current, "session_id", Ecto.UUID.generate())
      Store.put("lease", other_id, other, peer.id, note.id)

      assert {:ok, [id]} = Sync.pending_ids(peer)
      assert id == note.id
      assert Store.get("lease", lease.lease_id, peer.id)["expires_at"] > shortened + 30_000
      assert Store.get("lease", other_id, peer.id) == other

      expired = Map.put(current, "expires_at", System.system_time(:millisecond) - 1)
      Store.put("lease", lease.lease_id, expired, peer.id, note.id)
      assert {:error, :lease_expired} = Sync.pending_ids(peer)
      assert Store.get("lease", lease.lease_id, peer.id) == expired
    end)
  end

  defp assert_poll(peer, expected) do
    task = async(fn -> Sync.pending_ids(peer) end)

    try do
      assert {:ok, ^expected} = Task.yield(task, 1_000)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp hold_lock(lock, finish \\ fn -> :ok end) do
    owner = self()

    task =
      async(fn ->
        Repo.transaction(fn ->
          lock.()
          send(owner, {:locked, self()})

          receive do
            :release_lock -> finish.()
          end
        end)
      end)

    assert_receive {:locked, pid}, 2_000
    assert pid == task.pid
    task
  end

  defp release_lock(task) do
    send(task.pid, :release_lock)
    assert {:ok, {:ok, _}} = Task.yield(task, 5_000)
  end

  defp await_peer_lock(id, attempts \\ 100)
  defp await_peer_lock(_id, 0), do: flunk("apply did not acquire peer lock")

  defp await_peer_lock(id, attempts) do
    if Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE SKIP LOCKED")) do
      Process.sleep(10)
      await_peer_lock(id, attempts - 1)
    else
      :ok
    end
  end

  defp async(work),
    do: Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn -> unboxed(work) end)

  defp unboxed(work),
    do:
      Oban.Testing.with_testing_mode(:manual, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, work)
      end)
end
