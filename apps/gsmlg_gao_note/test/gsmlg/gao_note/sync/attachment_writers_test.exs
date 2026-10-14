defmodule GSMLG.GaoNote.Sync.AttachmentWritersTest do
  use GSMLG.GaoNote.DataCase, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}
  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker

  defmodule ObjectStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    put "/*path" do
      {:ok, _, conn} = read_body(conn)
      send_resp(conn, 200, "")
    end

    get "/*path" do
      if Application.get_env(:gsmlg_gao_note, :attachment_writer_read_fail, false),
        do: send_resp(conn, 503, "read unavailable"),
        else: send_resp(conn, 200, "hello")
    end

    delete("/*path", do: send_resp(conn, 204, ""))
  end

  setup do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: ObjectStub, port: port, startup_log: false})

    config = %{
      allowed_types: %{"gao_note_attachment" => :any},
      s3_access_key_id: "test",
      s3_secret_access_key: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_bucket: "sync-test"
    }

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    on_exit(fn ->
      Application.delete_env(:gsmlg_gao_note, :attachment_writer_read_fail)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    assert {:ok, peer} =
             Sync.register_peer(%{
               node_id: Ecto.UUID.generate(),
               certificate_fingerprint:
                 :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower),
               actor_id: "sync-test",
               allowed_selectors: ["project=bear_note"]
             })

    assert {:ok, _} = Sync.select(peer.id, ["project=bear_note"])
    %{peer: peer}
  end

  test "captures final compatibility IDs and keeps them across native reconciliation", %{
    peer: peer
  } do
    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Attachments",
                 content: "body",
                 labels: [{"project", "bear_note"}],
                 attachments: [
                   %{id: "event", path: "./doc.txt", mime: "text/plain", content: "hello"}
                 ]
               },
               nil
             )

    [event] = Sync.pending(peer.id)
    assert [%{"id" => "event", "path" => "doc.txt"}] = event["snapshot"]["attachments"]
    [attachment] = note.attachments

    assert {:ok, updated} =
             GaoNote.update_note(
               note,
               %{
                 content: "native",
                 attachments: [
                   %{
                     id: attachment.id,
                     path: "./moved.txt",
                     mime: "text/plain",
                     description: "Moved"
                   }
                 ]
               },
               nil
             )

    [native] = Sync.pending(peer.id)

    assert [%{"id" => "event", "path" => "moved.txt", "description" => "Moved"}] =
             native["snapshot"]["attachments"]

    assert updated.content == "native"

    assert {:ok, _} =
             Compat.put_note_attachment(
               note.id,
               "event",
               updated.revision,
               %{
                 path: "./moved.txt",
                 mime: "text/plain",
                 description: "Edited",
                 content: "world"
               },
               nil
             )

    [targeted] = Sync.pending(peer.id)

    assert [%{"id" => "event", "description" => "Edited", "checksum_sha256" => checksum}] =
             targeted["snapshot"]["attachments"]

    assert checksum == :crypto.hash(:sha256, "world") |> Base.encode16(case: :lower)
  end

  test "immutable metadata prevents reads and normalizes checksum case for unchanged bytes", %{
    peer: peer
  } do
    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Metadata",
                 content: "body",
                 labels: [{"project", "bear_note"}],
                 attachments: [
                   %{id: "event", path: "./doc.txt", mime: "text/plain", content: "hello"}
                 ]
               },
               nil
             )

    [first] = Sync.pending(peer.id)
    [attachment] = note.attachments
    file = GSMLG.Storage.get(attachment.storage_file_id)

    GSMLG.Storage.TestCatalogClient.update_file!(
      Ecto.Changeset.change(file, checksum: String.upcase(file.checksum))
    )

    Application.put_env(:gsmlg_gao_note, :attachment_writer_read_fail, true)

    assert {:ok, _} =
             GaoNote.put_attachment(
               note.id,
               attachment.id,
               %{
                 path: "./doc.txt",
                 mime: "text/plain",
                 description: "",
                 update_content: true,
                 content: "hello"
               },
               nil
             )

    assert [^first] = Sync.pending(peer.id)
  end

  test "legacy metadata compares existing bytes before deciding a replacement is unchanged", %{
    peer: peer
  } do
    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Legacy",
                 content: "body",
                 labels: [{"project", "bear_note"}],
                 attachments: [
                   %{id: "event", path: "./doc.txt", mime: "text/plain", content: "hello"}
                 ]
               },
               nil
             )

    [first] = Sync.pending(peer.id)
    [attachment] = note.attachments
    file = GSMLG.Storage.get(attachment.storage_file_id)

    GSMLG.Storage.TestCatalogClient.update_file!(
      Ecto.Changeset.change(file, checksum: "legacy-digest")
    )

    assert {:ok, _} =
             GaoNote.put_attachment(
               note.id,
               attachment.id,
               %{
                 path: "./doc.txt",
                 mime: "text/plain",
                 description: "",
                 update_content: true,
                 content: "hello"
               },
               nil
             )

    assert [^first] = Sync.pending(peer.id)
  end

  test "an active read lease protects the old object after pending work coalesces", %{peer: peer} do
    assert {:ok, %{peer: session}} =
             Sync.join(peer, %{
               "protocol_version" => 1,
               "node_id" => peer.id,
               "selectors" => ["project=bear_note"],
               "max_blob_bytes" => 536_870_912
             })

    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Leased",
                 content: "body",
                 labels: [{"project", "bear_note"}],
                 attachments: [
                   %{id: "event", path: "./doc.txt", mime: "text/plain", content: "hello"}
                 ]
               },
               nil
             )

    [attachment] = note.attachments
    assert {:ok, %{lease_id: lease_id, event: sent}} = Sync.checkout(session, note.id)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)
    [newer] = Sync.pending(peer.id)
    refute newer["event_id"] == sent["event_id"]
    assert newer["snapshot"]["attachments"] == []

    job = %Oban.Job{args: %{"storage_file_id" => attachment.storage_file_id}}
    assert {:snooze, 60} = StorageFilePurgeWorker.perform(job)
    descriptor = Map.delete(sent, "snapshot")

    assert {:error, _} =
             Sync.ack(
               session,
               Map.put(descriptor, "snapshot_hash", String.duplicate("a", 64)),
               lease_id
             )

    assert {:snooze, 60} = StorageFilePurgeWorker.perform(job)
    assert :ok = Sync.ack(session, descriptor, lease_id)
    assert [^newer] = Sync.pending(peer.id)
    assert :ok = StorageFilePurgeWorker.perform(job)
  end

  test "cleanup defers while a native reference exists and prevents reuse after deletion", %{
    peer: peer
  } do
    assert {:ok, note} =
             Compat.save_note(
               %{
                 title: "Protected",
                 content: "body",
                 labels: [{"project", "bear_note"}],
                 attachments: [
                   %{id: "event", path: "./doc.txt", mime: "text/plain", content: "hello"}
                 ]
               },
               nil
             )

    [attachment] = note.attachments

    assert {:snooze, 60} =
             StorageFilePurgeWorker.perform(%Oban.Job{
               args: %{"storage_file_id" => attachment.storage_file_id}
             })

    assert [_] = Sync.pending(peer.id)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)

    assert :ok =
             StorageFilePurgeWorker.perform(%Oban.Job{
               args: %{"storage_file_id" => attachment.storage_file_id}
             })

    assert {:error, :object_unavailable} =
             Repo.transaction(fn -> Sync.lock_objects([attachment.storage_file_id]) end)
             |> elem(1)
  end

  test "an abandoned read lease expires without reconnect and retains the latest pending work", %{
    peer: peer
  } do
    {:ok, %{peer: session}} = Sync.join(peer, join_payload(peer))
    {:ok, note} = leased_note()
    [attachment] = note.attachments
    {:ok, lease} = Sync.checkout(session, note.id)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)
    [newer] = Sync.pending(peer.id)
    job = %Oban.Job{args: %{"storage_file_id" => attachment.storage_file_id}}
    assert {:snooze, 60} = StorageFilePurgeWorker.perform(job)

    data = Store.get("lease", lease.lease_id, peer.id)
    Store.put("lease", lease.lease_id, Map.put(data, "expires_at", 0), peer.id, note.id)

    assert {:error, :ack_mismatch} = Sync.ack(session, Protocol.ack(lease.event), lease.lease_id)
    assert :ok = StorageFilePurgeWorker.perform(job)
    assert Store.get("lease", lease.lease_id, peer.id) == nil
    assert Store.get("ack", lease.lease_id, peer.id) == nil
    assert [^newer] = Sync.pending(peer.id)
    assert {:error, :ack_mismatch} = Sync.ack(session, Protocol.ack(lease.event), lease.lease_id)
  end

  test "pending polling renews only live leases and never recreates an expired owner", %{
    peer: peer
  } do
    {:ok, %{peer: session}} = Sync.join(peer, join_payload(peer))
    {:ok, note} = leased_note()
    [attachment] = note.attachments
    {:ok, lease} = Sync.checkout(session, note.id)
    assert %{"expires_at" => initial_expiry} = Store.get("lease", lease.lease_id, peer.id)
    assert initial_expiry > System.system_time(:millisecond)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)
    data = Store.get("lease", lease.lease_id, peer.id)
    short_expiry = System.system_time(:millisecond) + 5_000

    Store.put(
      "lease",
      lease.lease_id,
      Map.put(data, "expires_at", short_expiry),
      peer.id,
      note.id
    )

    assert {:ok, [id]} = Sync.pending_ids(session)
    assert id == note.id
    assert %{"expires_at" => renewed_expiry} = Store.get("lease", lease.lease_id, peer.id)
    assert renewed_expiry > short_expiry

    assert {:snooze, 60} =
             StorageFilePurgeWorker.perform(%Oban.Job{
               args: %{"storage_file_id" => attachment.storage_file_id}
             })

    data = Store.get("lease", lease.lease_id, peer.id)
    Store.put("lease", lease.lease_id, Map.put(data, "expires_at", 0), peer.id, note.id)
    assert {:error, :lease_expired} = Sync.pending_ids(session)

    assert :ok =
             StorageFilePurgeWorker.perform(%Oban.Job{
               args: %{"storage_file_id" => attachment.storage_file_id}
             })

    assert {:ok, [^id]} = Sync.pending_ids(session)
    assert Store.get("lease", lease.lease_id, peer.id) == nil
  end

  defp leased_note do
    Compat.save_note(
      %{
        title: "leased",
        content: "body",
        labels: [["project", "bear_note"]],
        attachments: [%{id: "public", path: "doc.txt", mime: "text/plain", content: "hello"}]
      },
      nil
    )
  end

  defp join_payload(peer),
    do: %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }
end
