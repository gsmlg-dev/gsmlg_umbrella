defmodule GSMLG.Storage.CleanupWorkerTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{CleanupWorker, StorageFile, TestCatalogClient}

  defmodule PayloadStub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    get "/*path" do
      send(
        Application.fetch_env!(:gsmlg_storage, :cleanup_test_pid),
        {:variant_read, conn.request_path}
      )

      send_resp(conn, 200, "image payload")
    end
  end

  defmodule FailedCatalogClient do
    def list_objects(_backend), do: {:error, :catalog_unavailable}
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    :ok = Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    TestCatalogClient.setup!()
    keys = [:s3_endpoint, :s3_bucket, :cleanup_test_pid, :variant_definitions]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: PayloadStub, port: port, startup_log: false})
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_bucket, "cleanup-test")
    Application.put_env(:gsmlg_storage, :cleanup_test_pid, self())
    Application.put_env(:gsmlg_storage, :variant_definitions, %{"attachment" => %{}})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    %{state: %{interval: :timer.hours(1), recovery_cursor: nil, variant_cursor: nil}}
  end

  test "ticks rotate past a full batch of permanently referenced expired intents", %{state: state} do
    note = Repo.insert!(%GSMLG.GaoNote.Note{title: "Protected cleanup intents", content: "body"})

    for n <- 1..100 do
      file = manifest(n, %{metadata: %{"sync_staging_expires_at" => "2020-01-01T00:00:00Z"}})

      Repo.insert!(%GSMLG.GaoNote.Attachment{
        id: "protected-#{n}",
        api_id: "protected-#{n}",
        note_id: note.id,
        storage_file_id: file.id,
        path: "./protected-#{n}.txt",
        mime: "text/plain"
      })
    end

    expired =
      manifest(101, %{
        status: "processing",
        metadata: %{"upload_expires_at" => "2020-01-01T00:00:00Z"}
      })

    assert {:noreply, state} = CleanupWorker.handle_info(:cleanup, state)
    assert state.recovery_cursor == ordered_id(100)
    assert %StorageFile{status: "processing"} = Storage.get(expired.id)

    assert {:noreply, state} = CleanupWorker.handle_info(:cleanup, state)
    assert state.recovery_cursor == ordered_id(99)
    assert %StorageFile{status: "deleted"} = Storage.get(expired.id)
    assert TestCatalogClient.count(status: "active") == 100
  end

  test "variant retries rotate after fifty attempts even when no variants are produced", %{
    state: state
  } do
    for n <- 1..51, do: manifest(n, %{content_type: "image/png"})
    assert {:noreply, state} = CleanupWorker.handle_info(:cleanup, state)
    assert state.variant_cursor == ordered_id(50)
    finish_variant_tasks()

    reads =
      for _ <- 1..50 do
        assert_receive {:variant_read, path}, 2_000
        path
      end

    refute "/cleanup-test/payload/51" in reads
    assert TestCatalogClient.count(status: "active") == 51

    assert {:noreply, state} = CleanupWorker.handle_info(:cleanup, state)
    assert state.variant_cursor == ordered_id(49)
    finish_variant_tasks()

    reads =
      for _ <- 1..50 do
        assert_receive {:variant_read, path}, 2_000
        path
      end

    assert "/cleanup-test/payload/51" in reads
    refute_receive {:variant_read, _}
  end

  test "catalog failure preserves cursor progress and the public error result", %{state: state} do
    state = %{state | recovery_cursor: ordered_id(25), variant_cursor: ordered_id(10)}
    Application.put_env(:gsmlg_storage, :catalog_s3_client, FailedCatalogClient)
    assert {:noreply, ^state} = CleanupWorker.handle_info(:cleanup, state)
    assert {:error, :catalog_unavailable} = CleanupWorker.run_cleanup()
  end

  test "manual cleanup keeps its public success result" do
    assert :ok = CleanupWorker.run_cleanup()
  end

  defp manifest(n, attrs) do
    defaults = %{
      tenant: "test",
      type: "attachment",
      filename: "#{n}.txt",
      s3_key: "payload/#{n}",
      content_type: "text/plain",
      size: 1,
      status: "active",
      metadata: %{}
    }

    %StorageFile{id: ordered_id(n)}
    |> StorageFile.changeset(Map.merge(defaults, attrs))
    |> TestCatalogClient.insert_file!()
  end

  defp ordered_id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")

  defp finish_variant_tasks do
    tasks = Task.Supervisor.children(GSMLG.TaskSupervisor)
    refs = Enum.map(tasks, &Process.monitor/1)
    for ref <- refs, do: assert_receive({:DOWN, ^ref, :process, _pid, _reason}, 5_000)
  end
end
