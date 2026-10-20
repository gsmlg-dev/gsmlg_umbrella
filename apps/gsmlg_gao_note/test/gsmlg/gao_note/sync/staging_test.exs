defmodule GSMLG.GaoNote.Sync.StagingTest do
  use ExUnit.Case, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  import Ecto.Query
  alias GSMLG.GaoNote.{Attachment, Attachments, Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Peer, Pin, Protocol, Record, Staging, Store}
  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  defmodule BlockingStore do
    def put_file(_bucket, key, path, _mime) do
      owner = Application.fetch_env!(:gsmlg_gao_note, :staging_test_owner)
      send(owner, {:object_put, self(), key, File.read!(path)})

      if owner == self() do
        :ok
      else
        receive do
          :finish_upload -> :ok
        end
      end
    end
  end

  defmodule BlockingCatalogStore do
    alias GSMLG.Storage.TestCatalogClient

    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient
    defdelegate list_objects(backend), to: TestCatalogClient

    def put_object(backend, key, data, content_type) do
      :ok = TestCatalogClient.put_object(backend, key, data, content_type)
      owner = Application.fetch_env!(:gsmlg_gao_note, :staging_test_owner)

      if owner != self() and Process.alive?(owner) and
           not Process.get({__MODULE__, :blocked}, false) do
        Process.put({__MODULE__, :blocked}, true)
        send(owner, {:catalog_put, self(), key})

        receive do
          :finish_catalog -> :ok
        end
      end

      :ok
    end
  end

  defmodule DeleteStore do
    use Plug.Router
    plug(:match)
    plug(:dispatch)
    delete("/*path", do: send_resp(conn, 204, ""))
  end

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    start_supervised!({Bandit, plug: DeleteStore, port: port, startup_log: false})

    config = %{
      s3_access_key_id: "test",
      s3_secret_access_key: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_bucket: "sync-staging-test",
      upload_s3_client: BlockingStore,
      allowed_types: %{"gao_note_attachment" => :any},
      max_file_size: 52_428_800
    }

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)
    Application.put_env(:gsmlg_gao_note, :staging_test_owner, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      Application.delete_env(:gsmlg_gao_note, :staging_test_owner)
    end)

    :ok
  end

  test "detected MIME and size policies reject before reserving or writing objects" do
    unboxed(fn ->
      tenant = Ecto.UUID.generate()
      jobs_before = recovery_jobs()

      on_exit(fn ->
        unboxed(fn ->
          Enum.filter(GSMLG.Storage.TestCatalogClient.files(), &(&1.tenant == tenant))
          |> Enum.each(fn file ->
            GSMLG.Storage.reject_upload(file)
            GSMLG.Storage.TestCatalogClient.delete_file!(file)

            Repo.delete_all(
              from(job in Styx.Job,
                where: fragment("?->>'storage_file_id'", job.args) == ^file.id
              )
            )
          end)
        end)
      end)

      Application.put_env(:gsmlg_storage, :allowed_types, %{
        "gao_note_attachment" => ["image/png"]
      })

      assert {:error, {:content_type_not_allowed, "text/plain", "gao_note_attachment"}} =
               Staging.upload({"file.txt", "staged bytes"}, tenant, "gao_note_attachment", [])

      Application.put_env(:gsmlg_storage, :max_file_size, 2)

      assert {:error, {:file_too_large, 12, 2}} =
               Staging.upload({"file.txt", "staged bytes"}, tenant, "gao_note_attachment", [])

      refute Enum.any?(GSMLG.Storage.TestCatalogClient.files(), &(&1.tenant == tenant))
      assert recovery_jobs() == jobs_before
      refute_receive {:object_put, _, _, _}
    end)
  end

  test "a killed object upload leaves a committed reservation and recovery job" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key))
      track(file)
      assert file.status == "processing"

      assert Repo.exists?(
               from(j in Styx.Job,
                 where:
                   j.worker == "GSMLG.GaoNote.Workers.StorageFilePurgeWorker" and
                     fragment("?->>'storage_file_id'", j.args) == ^file.id
               )
             )

      monitor = Process.monitor(uploader)
      Process.exit(uploader, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^uploader, :killed}, 5_000
      assert_receive {:DOWN, ref, :process, ^uploader, :killed}, 5_000
      assert ref == task.ref
      assert {:snooze, _} = recover(file)
      expire(file)
      assert :ok = recover(file)
      refute GSMLG.Storage.get(file.id)
    end)
  end

  test "a killed owner after finalization leaves its abandoned active object recoverable" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key))
      track(file)
      send(uploader, :finish_upload)
      assert_receive {:prepared, ^uploader, %{staged_files: [%StorageFile{id: id}]}}, 5_000
      assert id == file.id
      assert GSMLG.Storage.TestCatalogClient.get_file!(id).status == "active"
      Process.exit(uploader, :kill)
      assert_receive {:DOWN, ref, :process, ^uploader, :killed}, 5_000
      assert ref == task.ref
      expire(file)
      assert :ok = recover(file)
      refute GSMLG.Storage.get(id)
    end)
  end

  test "an upload beyond fifteen seconds retains its object lock and remains recoverable" do
    unboxed(fn ->
      task = upload_task()

      try do
        assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
        file = Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key))
        track(file)
        assert file.status == "processing"

        assert Repo.exists?(
                 from(j in Styx.Job,
                   where:
                     j.worker == "GSMLG.GaoNote.Workers.StorageFilePurgeWorker" and
                       fragment("?->>'storage_file_id'", j.args) == ^file.id
                 )
               )

        Process.sleep(16_100)

        # A recovery worker must still be excluded by the uploader's real SQL lock.
        assert %{rows: [[false]]} =
                 Repo.query!(
                   "SELECT pg_try_advisory_xact_lock(hashtextextended($1, 0))",
                   ["gao-note-sync:object:" <> file.id]
                 )

        assert GSMLG.Storage.TestCatalogClient.get_file!(file.id).status == "processing"
        send(uploader, :finish_upload)
        assert_receive {:prepared, ^uploader, %{staged_files: [%StorageFile{id: id}]}}, 5_000
        assert id == file.id
        assert GSMLG.Storage.get_active(file.id)
        send(uploader, :done)
        assert {:ok, :ok} = Task.yield(task, 5_000)

        assert {:snooze, _} = recover(file)
        expire(file)
        assert :ok = recover(file)
        refute GSMLG.Storage.get(file.id)
      after
        send(task.pid, :finish_upload)
        send(task.pid, :done)
        Task.shutdown(task, 5_000)
      end
    end)
  end

  test "a reservation catalog write beyond fifteen seconds commits its recovery job" do
    Application.put_env(:gsmlg_storage, :catalog_s3_client, BlockingCatalogStore)

    unboxed(fn ->
      task = upload_task()

      try do
        assert_receive {:catalog_put, uploader, _key}, 5_000
        [file] = GSMLG.Storage.TestCatalogClient.files()
        track(file)
        assert file.status == "processing"

        refute Repo.exists?(
                 from(j in Styx.Job,
                   where: fragment("?->>'storage_file_id'", j.args) == ^file.id
                 )
               )

        Process.sleep(16_100)
        send(uploader, :finish_catalog)
        assert_receive {:object_put, ^uploader, _key, "staged bytes"}, 5_000

        assert Repo.exists?(
                 from(j in Styx.Job,
                   where:
                     j.worker == "GSMLG.GaoNote.Workers.StorageFilePurgeWorker" and
                       fragment("?->>'storage_file_id'", j.args) == ^file.id
                 )
               )

        send(uploader, :finish_upload)
        assert_receive {:prepared, ^uploader, %{staged_files: [%StorageFile{id: id}]}}, 5_000
        assert id == file.id
        assert GSMLG.Storage.get_active(file.id)
        send(uploader, :done)
        assert {:ok, :ok} = Task.yield(task, 5_000)
        assert {:snooze, _} = recover(file)
        expire(file)
        assert :ok = recover(file)
        refute GSMLG.Storage.get(file.id)
      after
        send(task.pid, :finish_catalog)
        send(task.pid, :finish_upload)
        send(task.pid, :done)
        Task.shutdown(task, 5_000)
      end
    end)
  end

  test "finalized staging remains protected after the old minute while a long apply can commit" do
    unboxed(fn ->
      assert {:ok, file} =
               Staging.upload(
                 {"file.txt", "staged bytes"},
                 Ecto.UUID.generate(),
                 "gao_note_attachment",
                 []
               )

      track(file)
      current = GSMLG.Storage.TestCatalogClient.get_file!(file.id)
      {:ok, expires_at, _} = DateTime.from_iso8601(current.metadata["sync_staging_expires_at"])

      # Advance the reservation's age by 61 seconds without sleeping or altering the clock.
      metadata =
        Map.put(
          current.metadata,
          "sync_staging_expires_at",
          DateTime.to_iso8601(DateTime.add(expires_at, -61))
        )

      GSMLG.Storage.TestCatalogClient.update_file!(
        Ecto.Changeset.change(current, metadata: metadata)
      )

      assert {:snooze, _} = recover(file)
      assert GSMLG.Storage.get_active(file.id)
      assert DateTime.diff(expires_at, DateTime.utc_now()) in 928..930

      job =
        Repo.one!(
          from(j in Styx.Job, where: fragment("?->>'storage_file_id'", j.args) == ^file.id)
        )

      assert abs(DateTime.diff(job.scheduled_at, expires_at)) <= 1

      expire(file)
      assert :ok = recover(file)
      refute GSMLG.Storage.get(file.id)
    end)
  end

  test "expired recovery preserves a committed attachment and a durable read pin" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key))
      track(file)
      send(uploader, :finish_upload)
      assert_receive {:prepared, ^uploader, plan}, 5_000
      send(uploader, :done)
      assert_receive {ref, :ok}, 5_000
      assert ref == task.ref
      Process.demonitor(task.ref, [:flush])
      {:ok, note} = Compat.save_note(%{title: "committed", content: "body"}, nil)

      on_exit(fn ->
        unboxed(fn -> Repo.delete_all(from(n in GSMLG.GaoNote.Note, where: n.id == ^note.id)) end)
      end)

      plan = %{plan | note_id: note.id}
      assert {:ok, {:ok, [_]}} = Repo.transaction(fn -> Attachments.reconcile(note.id, plan) end)
      expire(file)
      assert {:snooze, _} = recover(file)
      assert GSMLG.Storage.TestCatalogClient.get_file!(file.id).status == "active"
      Repo.delete_all(from(a in Attachment, where: a.storage_file_id == ^file.id))
      owner = Ecto.UUID.generate()
      Repo.insert!(%Record{id: owner, kind: "lease", data: %{}})
      Repo.insert!(%Pin{owner_id: owner, storage_file_id: file.id})
      assert {:snooze, _} = recover(file)
      assert GSMLG.Storage.TestCatalogClient.get_file!(file.id).status == "active"
      Repo.delete_all(from(p in Pin, where: p.owner_id == ^owner))
      Repo.delete_all(from(r in Record, where: r.id == ^owner))
      assert :ok = recover(file)
    end)
  end

  test "a validated committed replay returns its durable ACK without staging another object" do
    unboxed(fn ->
      {peer, event, bytes} = incoming_attachment()
      assert {:ok, ack} = Sync.apply(peer, event, bytes)
      assert_receive {:object_put, _, key, "staged bytes"}
      file = Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key))
      track(file)
      receipt = Repo.get!(Record, Store.key("received", peer.id, event["event_id"]))

      assert {:ok, ^ack} = Sync.apply(peer, event, bytes)
      refute_receive {:object_put, _, _, _}
      assert Repo.get!(Record, receipt.id) == receipt
      assert [attachment] = Repo.all(from(a in Attachment, where: a.note_id == ^event["note_id"]))
      assert attachment.storage_file_id == file.id

      assert {:error, {:note_rejected, "validation_failed"}} = Sync.apply(peer, event, %{})
      refute_receive {:object_put, _, _, _}

      assert :ok = GSMLG.GaoNote.Sync.Peers.revoke(peer.id)
      assert {:error, :obsolete_session} = Sync.apply(peer, event, bytes)
      refute_receive {:object_put, _, _, _}
    end)
  end

  test "a reused event ID with different validated bytes fails before staging" do
    unboxed(fn ->
      {peer, event, bytes} = incoming_attachment()
      assert {:ok, _} = Sync.apply(peer, event, bytes)
      assert_receive {:object_put, _, key, "staged bytes"}
      track(Enum.find(GSMLG.Storage.TestCatalogClient.files(), &(&1.s3_key == key)))
      [descriptor] = event["snapshot"]["attachments"]
      replacement = "replacement bytes"

      snapshot =
        Map.put(event["snapshot"], "attachments", [
          Map.merge(descriptor, %{
            "size_bytes" => byte_size(replacement),
            "checksum_sha256" => Protocol.sha256(replacement)
          })
        ])

      conflict =
        Map.merge(event, %{
          "snapshot" => snapshot,
          "snapshot_hash" => Protocol.snapshot_hash(snapshot)
        })

      assert {:error, :event_id_conflict} =
               Sync.apply(peer, conflict, %{descriptor["id"] => replacement})

      refute_receive {:object_put, _, _, _}
    end)
  end

  test "a receipt arriving during staging is rechecked and staged objects are cleaned on conflict" do
    unboxed(fn ->
      {peer, event, bytes} = incoming_attachment()
      handler = {__MODULE__, make_ref()}

      :ok =
        :telemetry.attach(
          handler,
          [:gsmlg, :gao_note, :sync, :apply, :stop],
          fn _, _, metadata, _ ->
            if metadata.event_id == event["event_id"] and metadata.phase == :prepare do
              Enum.each(GSMLG.Storage.TestCatalogClient.files(), fn file ->
                if file.metadata["note_id"] == event["note_id"], do: track(file)
              end)

              Store.put(
                "received",
                event["event_id"],
                %{"event_hash" => "conflict"},
                peer.id,
                event["note_id"]
              )
            end
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:error, :event_id_conflict} = Sync.apply(peer, event, bytes)
      assert_receive {:object_put, _, _, "staged bytes"}
      refute Repo.get(GSMLG.GaoNote.Note, event["note_id"])

      refute Enum.any?(GSMLG.Storage.TestCatalogClient.files(), fn file ->
               file.metadata["note_id"] == event["note_id"] and file.status == "active"
             end)
    end)
  end

  defp incoming_attachment do
    id = Ecto.UUID.generate()
    value = Ecto.UUID.generate()

    {:ok, registered} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: Protocol.sha256(value),
        actor_id: "receipt-test",
        allowed_selectors: ["sync_receipt_test=" <> value]
      })

    {:ok, %{peer: peer}} =
      Sync.join(registered, %{
        "protocol_version" => 1,
        "node_id" => registered.id,
        "selectors" => registered.allowed_selectors,
        "max_blob_bytes" => 536_870_912
      })

    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(a in Attachment, where: a.note_id == ^id))
        Repo.delete_all(from(r in Record, where: r.peer_id == ^peer.id or r.note_id == ^id))
        Repo.delete_all(from(n in GSMLG.GaoNote.Note, where: n.id == ^id))
        Repo.delete_all(from(p in Peer, where: p.id == ^peer.id))
      end)
    end)

    attachment_id = Ecto.UUID.generate()
    content = "staged bytes"

    snapshot = %{
      "title" => "receipt test",
      "content" => "body",
      "created_at" => 1,
      "updated_at" => 1,
      "deleted_at" => nil,
      "labels" => [
        %{
          "key" => "sync_receipt_test",
          "value" => value,
          "description" => "",
          "value_type" => "text"
        }
      ],
      "attachments" => [
        %{
          "id" => attachment_id,
          "path" => "file.txt",
          "mime" => "text/plain",
          "description" => "",
          "size_bytes" => byte_size(content),
          "checksum_sha256" => Protocol.sha256(content)
        }
      ]
    }

    stamp = %{"millis" => 1000, "counter" => 0, "node_id" => peer.id}

    event = %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => id,
      "generation" => stamp,
      "control" => stamp,
      "version" => stamp,
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    }

    {peer, event, %{attachment_id => content}}
  end

  defp upload_task do
    owner = self()

    Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
      Styx.Testing.with_testing_mode(:manual, fn ->
        unboxed(fn ->
          {:ok, plan} =
            Attachments.prepare_sync(
              Ecto.UUID.generate(),
              [
                %{
                  id: "public",
                  path: "file.txt",
                  mime: "text/plain",
                  description: "",
                  content: "staged bytes"
                }
              ],
              "peer"
            )

          send(owner, {:prepared, self(), plan})

          receive do
            :done -> :ok
          end
        end)
      end)
    end)
  end

  defp recover(file),
    do: StorageFilePurgeWorker.perform(%Styx.Job{args: %{"storage_file_id" => file.id}})

  defp recovery_jobs,
    do:
      Repo.all(
        from(job in Styx.Job,
          where: job.worker == "GSMLG.GaoNote.Workers.StorageFilePurgeWorker",
          order_by: job.id,
          select: job.id
        )
      )

  defp expire(file) do
    current = GSMLG.Storage.TestCatalogClient.get_file!(file.id)

    metadata =
      Map.put(
        current.metadata,
        "sync_staging_expires_at",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
      )

    GSMLG.Storage.TestCatalogClient.update_file!(
      Ecto.Changeset.change(current, metadata: metadata)
    )
  end

  defp track(file) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(a in Attachment, where: a.storage_file_id == ^file.id))
        Repo.delete_all(from(p in Pin, where: p.storage_file_id == ^file.id))

        Repo.delete_all(
          from(j in Styx.Job, where: fragment("?->>'storage_file_id'", j.args) == ^file.id)
        )

        if current = GSMLG.Storage.get(file.id) do
          GSMLG.Storage.reject_upload(current)
          GSMLG.Storage.TestCatalogClient.delete_file!(current)
        end
      end)
    end)
  end

  defp unboxed(work),
    do:
      Styx.Testing.with_testing_mode(:manual, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, work)
      end)
end
