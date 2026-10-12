defmodule GSMLG.GaoNote.Sync.StagingTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  alias GSMLG.GaoNote.{Attachment, Attachments, Compat}
  alias GSMLG.GaoNote.Sync.{Pin, Record, Staging}
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
          Repo.all(from(file in StorageFile, where: file.tenant == ^tenant))
          |> Enum.each(fn file ->
            GSMLG.Storage.reject_upload(file)
            Repo.delete!(file)

            Repo.delete_all(
              from(job in Oban.Job,
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

      refute Repo.exists?(from(file in StorageFile, where: file.tenant == ^tenant))
      assert recovery_jobs() == jobs_before
      refute_receive {:object_put, _, _, _}
    end)
  end

  test "a killed object upload leaves a committed reservation and recovery job" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Repo.get_by!(StorageFile, s3_key: key)
      track(file)
      assert file.status == "processing"

      assert Repo.exists?(
               from(j in Oban.Job,
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
      refute Repo.get(StorageFile, file.id)
    end)
  end

  test "a killed owner after finalization leaves its abandoned active object recoverable" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Repo.get_by!(StorageFile, s3_key: key)
      track(file)
      send(uploader, :finish_upload)
      assert_receive {:prepared, ^uploader, %{staged_files: [%StorageFile{id: id}]}}, 5_000
      assert id == file.id
      assert Repo.get!(StorageFile, id).status == "active"
      Process.exit(uploader, :kill)
      assert_receive {:DOWN, ref, :process, ^uploader, :killed}, 5_000
      assert ref == task.ref
      expire(file)
      assert :ok = recover(file)
      refute Repo.get(StorageFile, id)
    end)
  end

  test "expired recovery preserves a committed attachment and a durable read pin" do
    unboxed(fn ->
      task = upload_task()
      assert_receive {:object_put, uploader, key, "staged bytes"}, 5_000
      file = Repo.get_by!(StorageFile, s3_key: key)
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
      assert Repo.get!(StorageFile, file.id).status == "active"
      Repo.delete_all(from(a in Attachment, where: a.storage_file_id == ^file.id))
      owner = Ecto.UUID.generate()
      Repo.insert!(%Record{id: owner, kind: "lease", data: %{}})
      Repo.insert!(%Pin{owner_id: owner, storage_file_id: file.id})
      assert {:snooze, _} = recover(file)
      assert Repo.get!(StorageFile, file.id).status == "active"
      Repo.delete_all(from(p in Pin, where: p.owner_id == ^owner))
      Repo.delete_all(from(r in Record, where: r.id == ^owner))
      assert :ok = recover(file)
    end)
  end

  defp upload_task do
    owner = self()

    Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
      Oban.Testing.with_testing_mode(:manual, fn ->
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
    do: StorageFilePurgeWorker.perform(%Oban.Job{args: %{"storage_file_id" => file.id}})

  defp recovery_jobs,
    do:
      Repo.all(
        from(job in Oban.Job,
          where: job.worker == "GSMLG.GaoNote.Workers.StorageFilePurgeWorker",
          order_by: job.id,
          select: job.id
        )
      )

  defp expire(file) do
    current = Repo.get!(StorageFile, file.id)

    metadata =
      Map.put(
        current.metadata,
        "sync_staging_expires_at",
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1))
      )

    Repo.update!(Ecto.Changeset.change(current, metadata: metadata))
  end

  defp track(file) do
    on_exit(fn ->
      unboxed(fn ->
        Repo.delete_all(from(a in Attachment, where: a.storage_file_id == ^file.id))
        Repo.delete_all(from(p in Pin, where: p.storage_file_id == ^file.id))

        Repo.delete_all(
          from(j in Oban.Job, where: fragment("?->>'storage_file_id'", j.args) == ^file.id)
        )

        if current = Repo.get(StorageFile, file.id) do
          GSMLG.Storage.reject_upload(current)
          Repo.delete!(current)
        end
      end)
    end)
  end

  defp unboxed(work),
    do:
      Oban.Testing.with_testing_mode(:manual, fn ->
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, work)
      end)
end
