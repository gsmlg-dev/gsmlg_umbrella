defmodule GSMLG.GaoNote.Workers.StorageFilePurgeWorkerTest do
  use ExUnit.Case, async: false
  use Oban.Testing, repo: GSMLG.Repo

  import Ecto.Query

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    delete "/*path" do
      if Application.get_env(:gsmlg_storage, :storage_purge_worker_test_fail, false) do
        send_resp(conn, 500, "delete failed")
      else
        send_resp(conn, 204, "")
      end
    end

    match _, do: send_resp(conn, 200, "")
  end

  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker
  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok
  end

  test "declares 24-hour worker-and-args uniqueness and prevents duplicate jobs" do
    storage_file_id = Ecto.UUID.generate()
    changeset = StorageFilePurgeWorker.new(%{storage_file_id: storage_file_id})
    job = Ecto.Changeset.apply_changes(changeset)

    assert job.queue == "storage_cleanup"
    assert job.max_attempts == 10
    assert %{fields: [:worker, :args], period: 86_400} = job.unique

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, first_job} = Oban.insert(changeset)

      assert {:ok, duplicate_job} =
               Oban.insert(StorageFilePurgeWorker.new(%{storage_file_id: storage_file_id}))

      refute first_job.conflict?
      assert duplicate_job.conflict?
      assert duplicate_job.id == first_job.id

      assert [%Oban.Job{id: enqueued_id}] =
               all_enqueued(
                 worker: StorageFilePurgeWorker,
                 args: %{storage_file_id: storage_file_id}
               )

      assert enqueued_id == first_job.id
    end)
  end

  test "purges an active GaoNote attachment with persisted empty variants" do
    with_s3_stub(fn ->
      file = insert_file(%{status: "active"})
      assert file.variants == %{}

      assert :ok =
               perform_job(StorageFilePurgeWorker, %{storage_file_id: file.id})

      assert nil == Storage.get(file.id)
    end)
  end

  test "purges an already-deleted storage file" do
    with_s3_stub(fn ->
      file = insert_file(%{status: "deleted"})

      assert :ok =
               perform_job(StorageFilePurgeWorker, %{storage_file_id: file.id})

      assert nil == Storage.get(file.id)
    end)
  end

  test "treats a missing storage file as already purged" do
    assert :ok =
             perform_job(StorageFilePurgeWorker, %{storage_file_id: Ecto.UUID.generate()})
  end

  test "cancels wrong-type files and files with variants" do
    wrong_type_file = insert_file(%{type: "attachment"})

    file_with_variants =
      insert_file(%{
        variants: %{
          "thumb" => %{"s3_key" => "gao_note/attachment/thumb.txt"}
        }
      })

    assert {:cancel, {:invalid_storage_file_type, "attachment"}} =
             perform_job(StorageFilePurgeWorker, %{
               storage_file_id: wrong_type_file.id
             })

    assert {:cancel, :storage_file_has_variants} =
             perform_job(StorageFilePurgeWorker, %{
               storage_file_id: file_with_variants.id
             })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, wrong_type_job} =
               Oban.insert(
                 StorageFilePurgeWorker.new(%{
                   storage_file_id: wrong_type_file.id
                 })
               )

      assert {:ok, variants_job} =
               Oban.insert(
                 StorageFilePurgeWorker.new(%{
                   storage_file_id: file_with_variants.id
                 })
               )

      _summary = Oban.drain_queue(queue: :storage_cleanup)

      assert Repo.get!(Oban.Job, wrong_type_job.id).state == "cancelled"
      assert Repo.get!(Oban.Job, variants_job.id).state == "cancelled"
    end)

    assert %StorageFile{status: "active"} = Storage.get(wrong_type_file.id)
    assert %StorageFile{status: "active"} = Storage.get(file_with_variants.id)
  end

  test "persists retryable storage failures and discards exhausted jobs" do
    with_s3_stub(fn ->
      Application.put_env(:gsmlg_storage, :storage_purge_worker_test_fail, true)
      retryable_file = insert_file(%{status: "active"})
      exhausted_file = insert_file(%{status: "active"})

      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, retryable_job} =
                 Oban.insert(
                   StorageFilePurgeWorker.new(%{storage_file_id: retryable_file.id})
                 )

        assert {:ok, discarded_job} =
                 Oban.insert(
                   StorageFilePurgeWorker.new(
                     %{storage_file_id: exhausted_file.id},
                     max_attempts: 1
                   )
                 )

        _summary = Oban.drain_queue(queue: :storage_cleanup)

        persisted_retryable_job = Repo.get!(Oban.Job, retryable_job.id)
        assert persisted_retryable_job.state == "retryable"
        assert persisted_retryable_job.attempt == 1

        persisted_discarded_job = Repo.get!(Oban.Job, discarded_job.id)
        assert persisted_discarded_job.state == "discarded"
        assert persisted_discarded_job.attempt == persisted_discarded_job.max_attempts
      end)

      assert %StorageFile{status: "deleted"} = Storage.get(retryable_file.id)
      assert %StorageFile{status: "deleted"} = Storage.get(exhausted_file.id)
    end)
  end

  test "cancels jobs with missing or malformed storage file IDs" do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, missing_id_job} = Oban.insert(StorageFilePurgeWorker.new(%{}))

      assert {:ok, malformed_id_job} =
               Oban.insert(
                 StorageFilePurgeWorker.new(%{storage_file_id: "not-a-uuid"})
               )

      _summary = Oban.drain_queue(queue: :storage_cleanup)

      assert Repo.get!(Oban.Job, missing_id_job.id).state == "cancelled"
      assert Repo.get!(Oban.Job, malformed_id_job.id).state == "cancelled"
    end)

    assert {:cancel, :invalid_storage_file_id} =
             perform_job(StorageFilePurgeWorker, %{storage_file_id: 123})
  end

  test "cancels unsupported storage file statuses without raising" do
    file = insert_file(%{status: "active"})

    assert {1, nil} =
             Repo.update_all(
               from(storage_file in StorageFile, where: storage_file.id == ^file.id),
               set: [status: "unsupported"]
             )

    assert {:cancel, {:unsupported_status, "unsupported"}} =
             perform_job(StorageFilePurgeWorker, %{storage_file_id: file.id})

    assert %StorageFile{status: "unsupported"} = Storage.get(file.id)
  end

  defp insert_file(attrs) do
    defaults = %{
      tenant: "gao_note",
      type: "gao_note_attachment",
      filename: "attachment.txt",
      s3_key: "gao_note/attachment/#{Ecto.UUID.generate()}.txt",
      content_type: "text/plain",
      size: 10,
      checksum: Ecto.UUID.generate(),
      metadata: %{},
      variants: %{},
      status: "active",
      uploaded_by: "test"
    }

    %StorageFile{}
    |> StorageFile.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end

  defp with_s3_stub(fun) do
    keys = [:s3_bucket, :s3_endpoint, :storage_purge_worker_test_fail]
    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :storage_purge_worker_test_fail, false)

    try do
      fun.()
    after
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      GenServer.stop(s3_stub)
    end
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
