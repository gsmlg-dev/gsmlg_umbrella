defmodule GSMLG.GaoNote.Sync.StorageCleanupTest do
  use GSMLG.GaoNote.DataCase, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Objects, Protocol, Store}
  alias GSMLG.Storage
  alias GSMLG.Storage.CleanupWorker

  defmodule ObjectStore do
    import Plug.Conn
    def init(table), do: table

    def call(%{method: "PUT"} = conn, table) do
      {:ok, bytes, conn} = read_body(conn)
      :ets.insert(table, {conn.request_path, bytes})
      send_resp(conn, 200, "")
    end

    def call(%{method: "DELETE"} = conn, table) do
      :ets.delete(table, conn.request_path)
      send_resp(conn, 204, "")
    end

    def call(%{method: "GET"} = conn, table) do
      case :ets.lookup(table, conn.request_path) do
        [{_, bytes}] ->
          case get_req_header(conn, "range") do
            [range] when bytes != "" ->
              [_, first, last] = Regex.run(~r/^bytes=(\d+)-(\d+)$/, range)
              first = String.to_integer(first)
              last = min(String.to_integer(last), byte_size(bytes) - 1)
              send_resp(conn, 206, binary_part(bytes, first, last - first + 1))

            _ ->
              send_resp(conn, 200, bytes)
          end

        [] ->
          send_resp(conn, 404, "")
      end
    end
  end

  setup do
    table = :ets.new(:storage_cleanup_objects, [:set, :public])
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Gaoxy.HTTP, plug: {ObjectStore, table}, port: port})

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
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    {:ok, peer} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: Protocol.sha256(Ecto.UUID.generate()),
        actor_id: "storage-cleanup",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, joined} =
      Sync.join(peer, %{
        "protocol_version" => 1,
        "node_id" => peer.id,
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      })

    %{peer: joined.peer, objects: table}
  end

  test "periodic cleanup retires an expired durable intent with no recovery job" do
    {:ok, file} =
      Storage.prepare_upload("abandoned", "gao_note_attachment", %{
        filename: "abandoned.txt",
        content_type: "text/plain",
        size: 0,
        checksum: Protocol.sha256(""),
        expires_at: DateTime.add(DateTime.utc_now(), 60)
      })

    refute Repo.exists?(
             from(job in Styx.Job,
               where: fragment("?->>'storage_file_id'", job.args) == ^file.id
             )
           )

    expired = Map.put(file.metadata, "upload_expires_at", "2000-01-01T00:00:00Z")
    GSMLG.Storage.TestCatalogClient.update_file!(Ecto.Changeset.change(file, metadata: expired))
    assert :ok = CleanupWorker.run_cleanup()
    assert Storage.get(file.id).status == "deleted"
    assert {:ok, _} = Storage.purge(Storage.get(file.id))
  end

  test "periodic cleanup preserves an expired staged object with a committed attachment or pin",
       %{peer: peer} do
    note = note_with_attachment()
    [attachment] = note.attachments
    attached = Storage.get(attachment.storage_file_id)
    {pinned, _lease} = leased_object(peer)

    Enum.each([attached, pinned], fn file ->
      metadata = Map.put(file.metadata, "sync_staging_expires_at", "2000-01-01T00:00:00Z")

      GSMLG.Storage.TestCatalogClient.update_file!(
        Ecto.Changeset.change(file, metadata: metadata)
      )

      Repo.delete_all(
        from(job in Styx.Job,
          where: fragment("?->>'storage_file_id'", job.args) == ^file.id
        )
      )
    end)

    assert :ok = CleanupWorker.run_cleanup()
    assert Storage.get(attached.id).status == "active"
    assert Storage.get(pinned.id).status == "active"
  end

  test "generic delete and upload rejection preserve referenced active files", %{objects: objects} do
    note = note_with_attachment()
    [attachment] = note.attachments
    file = Storage.get(attachment.storage_file_id)
    assert {:error, :file_referenced} = Storage.delete(file.id)
    assert {:error, :file_referenced} = Storage.reject_upload(file)
    assert Storage.get(file.id).status == "active"
    assert :ets.tab2list(objects) != []
  end

  test "a pending frozen detach protects bytes after the native reference is removed", %{
    peer: peer
  } do
    note = note_with_attachment()
    [attachment] = note.attachments
    assert {:ok, detached} = Compat.patch_note(note.id, note.revision, %{labels: []}, nil)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)

    refute Repo.exists?(
             from(a in Attachment, where: a.storage_file_id == ^attachment.storage_file_id)
           )

    assert [%{"kind" => "detach"}] = Sync.pending(peer.id)
    assert {:error, :file_referenced} = Storage.delete(attachment.storage_file_id)
    assert detached.note.id == note.id
  end

  test "an active read lease protects a replaced object until exact ACK", %{
    peer: peer,
    objects: objects
  } do
    {file, lease} = leased_object(peer)
    assert {:error, :file_referenced} = Storage.delete(file)
    assert Storage.get(file.id).status == "active"
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    assert {:ok, deleted} = Storage.delete(file)
    assert {:ok, _} = Storage.purge(deleted)
    assert :ets.tab2list(objects) == []
  end

  test "an expired read lease is retired before an unreferenced object is deleted", %{peer: peer} do
    {file, lease} = leased_object(peer)
    data = Store.get("lease", lease.lease_id, peer.id)

    Store.put(
      "lease",
      lease.lease_id,
      Map.put(data, "expires_at", 0),
      peer.id,
      lease.event["note_id"]
    )

    assert {:ok, deleted} = Storage.delete(file)
    assert Store.get("lease", lease.lease_id, peer.id) == nil
    assert {:ok, _} = Storage.purge(deleted)
  end

  test "folder deletion preserves every file and directory marker when a selected file is referenced",
       %{objects: objects} do
    note = note_with_attachment()
    [attachment] = note.attachments
    protected = Storage.get(attachment.storage_file_id)

    {:ok, loose} =
      Storage.upload({"loose.txt", "loose"}, protected.tenant, protected.type, variants: [])

    {:ok, _folder} = Storage.create_folder(protected.tenant, protected.type)
    assert {:error, :file_referenced} = Storage.delete_folder(protected.tenant, protected.type)
    assert Storage.get(protected.id).status == "active"
    assert Storage.get(loose.id).status == "active"
    assert :ets.lookup(objects, "/sync-test/#{protected.tenant}/#{protected.type}/") != []
  end

  test "folder deletion retains year and month filtering while blocking protected candidates" do
    note = note_with_attachment()
    [attachment] = note.attachments
    protected = Storage.get(attachment.storage_file_id)

    {:ok, loose} =
      Storage.upload({"loose.txt", "loose"}, protected.tenant, protected.type, variants: [])

    GSMLG.Storage.TestCatalogClient.update_file!(
      Ecto.Changeset.change(loose, inserted_at: ~U[2020-01-01 00:00:00.000000Z])
    )

    assert {:ok, :ok} = Storage.delete_folder(protected.tenant, protected.type, 2020, 1)
    assert Storage.get(loose.id).status == "deleted"
    assert Storage.get(protected.id).status == "active"

    assert {:error, :file_referenced} =
             Storage.delete_folder(
               protected.tenant,
               protected.type,
               protected.inserted_at.year,
               protected.inserted_at.month
             )
  end

  test "purge and periodic cleanup preserve a legacy deleted object with live pins", %{
    peer: peer,
    objects: objects
  } do
    {file, _lease} = leased_object(peer)

    deleted =
      GSMLG.Storage.TestCatalogClient.update_file!(
        Ecto.Changeset.change(file,
          status: "deleted",
          updated_at: ~U[2000-01-01 00:00:00.000000Z]
        )
      )

    assert {:error, :file_referenced} = Storage.purge(deleted)
    assert {:noreply, _} = CleanupWorker.handle_info(:cleanup, %{interval: 3_600_000})
    assert :ets.tab2list(objects) != []
    assert Storage.get(file.id)
  end

  test "stale structs cannot bypass fresh status or references", %{peer: peer} do
    {file, _lease} = leased_object(peer)

    assert {:error, :file_referenced} =
             Storage.delete(%{file | type: "document", status: "deleted"})

    assert {:error, :not_deleted} = Storage.purge(%{file | status: "deleted"})
    assert Storage.get(file.id).status == "active"
  end

  test "ordinary unreferenced files can be deleted, purged and rejected" do
    {:ok, file} = Storage.upload({"plain.txt", "plain"}, "plain", "document", variants: [])
    assert {:ok, deleted} = Storage.delete(file)
    assert {:ok, _} = Storage.purge(%{deleted | s3_key: "stale-key"})
    assert Storage.get(file.id) == nil
    {:ok, other} = Storage.upload({"other.txt", "other"}, "plain", "document", variants: [])
    assert {:ok, rejected} = Storage.reject_upload(other)
    assert {:ok, _} = Storage.purge(rejected)
  end

  test "ordinary storage still deletes files when GaoNote tables are absent" do
    Repo.query!("SET LOCAL search_path TO pg_temp")

    {:ok, file} =
      Storage.upload({"standalone.txt", "standalone"}, "standalone", "document", variants: [])

    assert {:ok, deleted} = Storage.delete(file)
    assert {:ok, _} = Storage.purge(deleted)
    assert Storage.get(file.id) == nil
  end

  test "uppercase UUID deletion waits for a pin transaction and observes its committed reference" do
    parent = self()

    file =
      unboxed(fn ->
        {:ok, file} =
          Storage.upload({"race.txt", "race"}, "race", "gao_note_attachment", variants: [])

        file
      end)

    identifier = Ecto.UUID.generate()
    record_id = Store.key("pending", nil, identifier)

    writer =
      Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
        unboxed(fn ->
          Repo.transaction(fn ->
            owner = Store.put("pending", identifier, %{})
            :ok = Objects.set(owner, %{"race" => file.id})
            send(parent, :pin_locked)
            receive do: (:commit -> :ok)
          end)
        end)
      end)

    assert_receive :pin_locked, 5_000

    deleter =
      Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
        unboxed(fn ->
          %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
          send(parent, {:deletion_backend, pid})
          Storage.reject_upload(String.upcase(file.id))
        end)
      end)

    try do
      assert_receive {:deletion_backend, pid}, 5_000
      await_advisory_wait(pid, System.monotonic_time(:millisecond) + 5_000)
      send(writer.pid, :commit)
      assert {:ok, :ok} = Task.await(writer, 5_000)
      assert {:error, :file_referenced} = Task.await(deleter, 5_000)
      assert unboxed(fn -> Storage.get(file.id).status end) == "active"
    after
      send(writer.pid, :commit)
      Task.shutdown(writer, :brutal_kill)
      Task.shutdown(deleter, :brutal_kill)

      unboxed(fn ->
        Repo.delete_all(from(r in "gao_note_sync_records", where: r.id == ^record_id))

        case Storage.delete(file.id) do
          {:ok, deleted} -> Storage.purge(deleted)
          _ -> :ok
        end
      end)
    end
  end

  defp await_advisory_wait(pid, deadline) do
    case Repo.query!("SELECT wait_event FROM pg_stat_activity WHERE pid = $1", [pid]).rows do
      [["advisory"]] ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < deadline,
               "deletion did not wait for the sync object lock"

        Process.sleep(10)
        await_advisory_wait(pid, deadline)
    end
  end

  defp unboxed(operation), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, operation)

  defp note_with_attachment do
    {:ok, note} =
      Compat.save_note(
        %{
          title: "protected",
          content: "body",
          labels: [["project", "bear_note"]],
          attachments: [%{id: "kept", path: "kept.txt", mime: "text/plain", content: "kept"}]
        },
        nil
      )

    note
  end

  defp leased_object(peer) do
    note = note_with_attachment()
    [attachment] = note.attachments
    file = Storage.get(attachment.storage_file_id)
    {:ok, lease} = Sync.checkout(peer, note.id)
    assert {:ok, _} = GaoNote.delete_attachment(note.id, attachment.id, nil)
    refute Repo.exists?(from(a in Attachment, where: a.storage_file_id == ^file.id))
    {file, lease}
  end
end
