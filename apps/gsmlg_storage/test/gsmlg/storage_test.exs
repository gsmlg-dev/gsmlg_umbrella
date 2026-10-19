defmodule GSMLG.StorageTest do
  use ExUnit.Case, async: false

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    put "/*path" do
      if pid = Application.get_env(:gsmlg_storage, :storage_test_pid) do
        send(pid, :s3_put)
        send(pid, {:s3_put_path, conn.request_path})
      end

      if String.ends_with?(conn.request_path, "/") do
        Agent.update(
          Application.fetch_env!(:gsmlg_storage, :storage_test_markers),
          &MapSet.put(&1, conn.request_path)
        )
      end

      send_resp(conn, 200, "")
    end

    delete "/*path" do
      if pid = Application.get_env(:gsmlg_storage, :storage_test_pid) do
        send(pid, {:s3_delete, conn.request_path})
      end

      failure_key =
        Application.get_env(:gsmlg_storage, :storage_test_delete_failure_key)

      if is_binary(failure_key) and String.ends_with?(conn.request_path, failure_key) do
        send_resp(conn, 500, "delete failed")
      else
        Agent.update(
          Application.fetch_env!(:gsmlg_storage, :storage_test_markers),
          &MapSet.delete(&1, conn.request_path)
        )

        send_resp(conn, 204, "")
      end
    end

    get "/*path" do
      range_headers = Plug.Conn.get_req_header(conn, "range")

      if pid = Application.get_env(:gsmlg_storage, :storage_test_pid) do
        send(pid, {:s3_get, range_headers})
      end

      if String.contains?(conn.query_string, "list-type=") do
        contents =
          Application.fetch_env!(:gsmlg_storage, :storage_test_markers)
          |> Agent.get(& &1)
          |> Enum.map_join(fn path ->
            key = String.replace_prefix(path, "/gsmlg-storage/", "")

            "<Contents><Key>#{URI.encode(key, &URI.char_unreserved?/1)}</Key><Size>0</Size><LastModified>2026-10-14T00:00:00Z</LastModified></Contents>"
          end)

        send_resp(
          conn,
          200,
          "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>#{contents}</ListBucketResult>"
        )
      else
        object = Application.get_env(:gsmlg_storage, :storage_test_object, "")
        {status, body} = range_response(object, range_headers)
        send_resp(conn, status, body)
      end
    end

    match(_, do: send_resp(conn, 200, ""))

    defp range_response(object, ["bytes=" <> range]) do
      [first, last] =
        range
        |> String.split("-", parts: 2)
        |> Enum.map(&String.to_integer/1)

      {206, binary_part(object, first, last - first + 1)}
    end

    defp range_response(object, _headers), do: {200, object}
  end

  defmodule FailingCatalogClient do
    alias GSMLG.Storage.TestCatalogClient

    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate list_objects(backend), to: TestCatalogClient

    def put_object(backend, key, data, content_type) do
      status = JSON.decode!(data)["status"]

      case {Process.get({__MODULE__, :failure}), status} do
        {:put, "active"} -> {:error, :manifest_write_failed}
        {:intent, "processing"} -> {:error, :manifest_write_failed}
        {:raise, "active"} -> raise "manifest write crashed"
        _ -> TestCatalogClient.put_object(backend, key, data, content_type)
      end
    end

    def delete_object(backend, key) do
      if Process.get({__MODULE__, :failure}) == :delete,
        do: {:error, :manifest_delete_failed},
        else: TestCatalogClient.delete_object(backend, key)
    end
  end

  defmodule OrderedCatalogClient do
    alias GSMLG.Storage.TestCatalogClient
    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate put_object(backend, key, data, content_type), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def list_objects(backend) do
      with {:ok, objects} <- TestCatalogClient.list_objects(backend),
           do: {:ok, Enum.sort_by(objects, & &1.key)}
    end
  end

  defmodule StaleSnapshotCatalogClient do
    alias GSMLG.Storage.TestCatalogClient
    defdelegate list_objects(backend), to: TestCatalogClient
    defdelegate put_object(backend, key, data, content_type), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def get_object(backend, key) do
      case Process.delete({__MODULE__, :snapshot}) do
        nil -> TestCatalogClient.get_object(backend, key)
        data -> {:ok, data}
      end
    end
  end

  alias GSMLG.Storage
  alias GSMLG.Storage.{StorageFile, TestCatalogClient}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GSMLG.Repo)
    TestCatalogClient.setup!()
    :ok
  end

  defp insert_file(attrs \\ %{}) do
    defaults = %{
      tenant: "test",
      type: "attachment",
      filename: "test.jpg",
      s3_key: "test/attachment/2026/03/#{Ecto.UUID.generate()}.jpg",
      content_type: "image/jpeg",
      size: 1024,
      checksum: Ecto.UUID.generate(),
      metadata: %{},
      variants: %{},
      status: "active",
      uploaded_by: "test"
    }

    %StorageFile{}
    |> StorageFile.changeset(Map.merge(defaults, attrs))
    |> TestCatalogClient.insert_file!()
  end

  defp with_s3_stub(fun) do
    keys = [
      :allowed_types,
      :s3_bucket,
      :s3_endpoint,
      :storage_test_pid,
      :storage_test_object,
      :storage_test_delete_failure_key,
      :max_file_size,
      :catalog_s3_client,
      :storage_test_markers
    ]

    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :allowed_types, %{"attachment" => :any})
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :storage_test_pid, self())
    markers = start_supervised!({Agent, fn -> MapSet.new() end}, id: :s3_markers)
    Application.put_env(:gsmlg_storage, :storage_test_markers, markers)

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

  describe "StorageFile.changeset/2" do
    test "accepts an explicit zero-byte file" do
      changeset =
        StorageFile.changeset(%StorageFile{}, %{
          tenant: "test",
          type: "attachment",
          filename: "empty.txt",
          s3_key: "test/attachment/empty.txt",
          content_type: "text/plain",
          size: 0
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :size) == 0
    end
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  describe "upload/4 input normalization" do
    test "rejects invalid input types" do
      assert {:error, :invalid_input} = Storage.upload(123, "tenant", "attachment")
      assert {:error, :invalid_input} = Storage.upload(nil, "tenant", "attachment")
    end

    test "uses filename-assisted text detection for allowlist validation" do
      original = Application.get_env(:gsmlg_storage, :allowed_types)

      on_exit(fn ->
        if original,
          do: Application.put_env(:gsmlg_storage, :allowed_types, original),
          else: Application.delete_env(:gsmlg_storage, :allowed_types)
      end)

      Application.put_env(:gsmlg_storage, :allowed_types, %{"restricted" => ~w(image/png)})

      result = Storage.upload({"test.txt", "hello world content"}, "tenant", "restricted")

      assert {:error, {:content_type_not_allowed, "text/plain", "restricted"}} =
               result
    end

    @tag :tmp_dir
    test "does not trust Plug.Upload content_type during allowlist validation", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "upload")
      File.write!(path, "# Server-derived Markdown\n")

      upload = %Plug.Upload{
        path: path,
        filename: "notes.md",
        content_type: "image/png"
      }

      original = Application.get_env(:gsmlg_storage, :allowed_types)

      on_exit(fn ->
        if original,
          do: Application.put_env(:gsmlg_storage, :allowed_types, original),
          else: Application.delete_env(:gsmlg_storage, :allowed_types)
      end)

      Application.put_env(:gsmlg_storage, :allowed_types, %{"restricted" => ~w(image/png)})

      assert {:error, {:content_type_not_allowed, "text/markdown", "restricted"}} =
               Storage.upload(upload, "tenant", "restricted")
    end

    test "rejects files exceeding max size" do
      original = Application.get_env(:gsmlg_storage, :max_file_size)
      Application.put_env(:gsmlg_storage, :max_file_size, 10)

      result = Storage.upload({"test.txt", String.duplicate("x", 100)}, "tenant", "attachment")
      assert {:error, {:file_too_large, 100, 10}} = result

      if original,
        do: Application.put_env(:gsmlg_storage, :max_file_size, original),
        else: Application.delete_env(:gsmlg_storage, :max_file_size)
    end

    test "sanitizes path-like filenames and preserves normal Unicode basenames" do
      with_s3_stub(fn ->
        assert {:ok, %StorageFile{filename: "file.txt"}} =
                 Storage.upload(
                   {"C:\\fakepath\\file.txt", "windows path"},
                   "tenant",
                   "attachment"
                 )

        assert {:ok, %StorageFile{filename: "file.txt"}} =
                 Storage.upload({"../../file.txt", "relative path"}, "tenant", "attachment")

        assert {:ok, %StorageFile{filename: "报告.txt"}} =
                 Storage.upload({"报告.txt", "unicode name"}, "tenant", "attachment")

        assert_receive :s3_put
        assert_receive :s3_put
        assert_receive :s3_put
      end)
    end

    test "rejects blank, dot, control, NUL, invalid UTF-8, and overlong filenames before S3" do
      with_s3_stub(fn ->
        count_before = TestCatalogClient.count()
        overlong_multibyte = String.duplicate("界", 84) <> ".txt"

        invalid_filenames = [
          "",
          "   ",
          ".",
          "..",
          "bad\0name.txt",
          "bad\nname.txt",
          <<"invalid-", 0xFF, ".txt">>,
          overlong_multibyte
        ]

        for filename <- invalid_filenames do
          assert {:error, :invalid_filename} =
                   Storage.upload({filename, "safe data"}, "tenant", "attachment")
        end

        assert byte_size(overlong_multibyte) > 255
        assert TestCatalogClient.count() == count_before
        refute_received :s3_put
      end)
    end

    test "rejects oversized data before classification, hashing, or S3" do
      with_s3_stub(fn ->
        Application.put_env(:gsmlg_storage, :max_file_size, 8)
        data = "<svg>\0" <> String.duplicate("x", 20)

        assert {:error, {:file_too_large, size, 8}} =
                 Storage.upload({"oversized.txt", data}, "tenant", "attachment")

        assert size == byte_size(data)
        refute_received :s3_put
      end)
    end

    test "variants: [] suppresses automatic generation for an image upload" do
      with_s3_stub(fn ->
        png =
          Base.decode64!(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
          )

        assert {:ok,
                %StorageFile{
                  type: "gao_note_attachment",
                  variants: %{}
                } = file} =
                 Storage.upload(
                   {"attachment.png", png},
                   "gao_note",
                   "gao_note_attachment",
                   variants: []
                 )

        assert %StorageFile{variants: %{}} = Storage.get(file.id)
        assert_receive :s3_put
        refute_receive {:s3_get, _headers}, 100
        refute_receive :s3_put, 100
      end)
    end

    test "a failed recovery intent write prevents any payload upload" do
      with_s3_stub(fn ->
        Application.put_env(:gsmlg_storage, :catalog_s3_client, FailingCatalogClient)
        Process.put({FailingCatalogClient, :failure}, :intent)

        assert {:error, :manifest_write_failed} =
                 Storage.upload({"intent.txt", "safe data"}, "tenant", "attachment", variants: [])

        assert TestCatalogClient.count() == 0
        refute_received :s3_put
      end)
    end

    test "an active manifest exception cleans the payload and preserves the original error" do
      with_s3_stub(fn ->
        Application.put_env(:gsmlg_storage, :catalog_s3_client, FailingCatalogClient)
        Process.put({FailingCatalogClient, :failure}, :raise)

        assert_raise RuntimeError, "manifest write crashed", fn ->
          Storage.upload({"crash.txt", "safe data"}, "tenant", "attachment", variants: [])
        end

        assert_receive {:s3_put_path, put_path}
        assert_receive {:s3_delete, ^put_path}
        assert TestCatalogClient.count(status: "active") == 0
        assert TestCatalogClient.count(status: "deleted") == 1
      end)
    end

    @tag :tmp_dir
    test "compensates manifest write failure without changing Plug.Upload", %{tmp_dir: tmp_dir} do
      with_s3_stub(fn ->
        path = Path.join(tmp_dir, "failing-upload")
        File.write!(path, "safe data")
        upload = %Plug.Upload{path: path, filename: "failing.txt", content_type: "text/plain"}
        Application.put_env(:gsmlg_storage, :catalog_s3_client, FailingCatalogClient)
        Process.put({FailingCatalogClient, :failure}, :put)

        assert {:error, :manifest_write_failed} =
                 Storage.upload(upload, "tenant", "attachment", variants: [])

        assert_receive :s3_put
        assert_receive {:s3_put_path, put_path}
        assert_receive {:s3_delete, ^put_path}
        assert TestCatalogClient.count(status: "active") == 0
        assert TestCatalogClient.count(status: "deleted") == 1
        assert File.read!(path) == "safe data"
      end)
    end

    test "a failed manifest write can be retried after the backend recovers" do
      with_s3_stub(fn ->
        Application.put_env(:gsmlg_storage, :catalog_s3_client, FailingCatalogClient)
        Process.put({FailingCatalogClient, :failure}, :put)

        assert {:error, :manifest_write_failed} =
                 Storage.upload({"retry.txt", "safe data"}, "tenant", "attachment", variants: [])

        assert TestCatalogClient.count(status: "active") == 0
        assert TestCatalogClient.count(status: "deleted") == 1

        Process.delete({FailingCatalogClient, :failure})

        assert {:ok, file} =
                 Storage.upload({"retry.txt", "safe data"}, "tenant", "attachment", variants: [])

        assert %StorageFile{id: id, filename: "retry.txt"} = Storage.get(file.id)
        assert id == file.id
        assert TestCatalogClient.count(status: "active") == 1
      end)
    end
  end

  describe "get/1 and get_active/1" do
    test "get/1 returns file by ID" do
      file = insert_file()
      assert %StorageFile{id: id} = Storage.get(file.id)
      assert id == file.id
    end

    test "get/1 returns nil for non-existent ID" do
      assert nil == Storage.get(Ecto.UUID.generate())
    end

    test "get_active/1 returns only active files" do
      file = insert_file(%{status: "active"})
      processing = insert_file(%{status: "processing"})
      deleted = insert_file(%{status: "deleted"})

      assert %StorageFile{} = Storage.get_active(file.id)
      assert nil == Storage.get_active(processing.id)
      assert nil == Storage.get_active(deleted.id)
    end
  end

  describe "captured backend guards" do
    test "stale range and variant readers reject a different current bucket" do
      with_s3_stub(fn ->
        file = insert_file(%{size: 10, variants: %{"thumb" => %{"s3_key" => "thumb.jpg"}}})
        Application.put_env(:gsmlg_storage, :s3_bucket, "another-bucket")

        assert {:error, :backend_changed} = Storage.read_range(file, 0, 1)
        assert {:error, :backend_changed} = Storage.stream_variant(file, "thumb")
        refute_received {:s3_get, _headers}
      end)
    end

    test "stale mutation structs cannot modify the same UUID in another bucket" do
      with_s3_stub(fn ->
        for {operation, status} <- [
              delete: "active",
              reject_upload: "processing",
              purge: "deleted"
            ] do
          Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
          original = insert_file(%{status: status})
          Application.put_env(:gsmlg_storage, :s3_bucket, "another-bucket")
          duplicate = TestCatalogClient.insert_file!(%{original | backend_id: nil})

          assert {:error, :backend_changed} = apply(Storage, operation, [original])
          assert %StorageFile{status: ^status} = Storage.get(duplicate.id)
        end

        refute_received {:s3_delete, _path}
      end)
    end
  end

  test "finalizing a rejected reservation cannot revive its deleted manifest" do
    with_s3_stub(fn ->
      data = "safe data"

      attrs = %{
        filename: "reservation.txt",
        content_type: "text/plain",
        size: byte_size(data),
        checksum: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      }

      assert {:ok, file} = Storage.prepare_upload("test", "attachment", attrs)
      assert :ok = Storage.write_upload(file.id, data)
      assert {:ok, %StorageFile{status: "deleted"}} = Storage.reject_upload(file)

      assert {:error, :invalid_upload_reservation} = Storage.finalize_upload(file.id)
      assert %StorageFile{status: "deleted"} = Storage.get(file.id)
      refute_received :s3_put
    end)
  end

  test "cleanup reaches an expired intent after the first hundred healthy manifests" do
    Application.put_env(:gsmlg_storage, :catalog_s3_client, OrderedCatalogClient)
    on_exit(fn -> Application.put_env(:gsmlg_storage, :catalog_s3_client, TestCatalogClient) end)

    for n <- 1..100 do
      file = %StorageFile{id: ordered_id(n)}

      attrs = %{
        tenant: "test",
        type: "attachment",
        filename: "healthy.txt",
        s3_key: "healthy/#{n}",
        content_type: "text/plain",
        size: 1
      }

      file |> StorageFile.changeset(attrs) |> TestCatalogClient.insert_file!()
    end

    expired =
      %StorageFile{id: ordered_id(101)}
      |> StorageFile.changeset(%{
        tenant: "test",
        type: "attachment",
        filename: "expired.txt",
        s3_key: "expired/intent",
        content_type: "text/plain",
        size: 1,
        status: "processing",
        metadata: %{"upload_expires_at" => "2020-01-01T00:00:00Z"}
      })
      |> TestCatalogClient.insert_file!()

    assert :ok = GSMLG.Storage.CleanupWorker.run_cleanup()
    assert %StorageFile{status: "deleted"} = Storage.get(expired.id)
    assert TestCatalogClient.count(status: "active") == 100
  end

  test "cleanup rechecks a finalized sync upload instead of deleting an expired stale processing snapshot" do
    file =
      insert_file(%{
        status: "processing",
        content_type: "text/plain",
        metadata: %{
          "upload_expires_at" => "2020-01-01T00:00:00Z",
          "sync_staging_expires_at" => "2020-01-01T00:00:00Z"
        }
      })

    {:ok, backend} = GSMLG.Storage.S3Client.capture_backend()
    {:ok, [object]} = TestCatalogClient.list_objects(backend)
    {:ok, expired_snapshot} = TestCatalogClient.get_object(backend, object.key)

    {:ok, _active} =
      file |> StorageFile.status_changeset(%{status: "active"}) |> GSMLG.Storage.Catalog.update()

    Application.put_env(:gsmlg_storage, :catalog_s3_client, StaleSnapshotCatalogClient)
    Process.put({StaleSnapshotCatalogClient, :snapshot}, expired_snapshot)

    assert :ok = GSMLG.Storage.CleanupWorker.run_cleanup()
    assert %StorageFile{status: "active"} = Storage.get(file.id)
  end

  defp ordered_id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")

  describe "read_range/3" do
    test "retrieves only the requested inclusive bytes for a file or ID" do
      with_s3_stub(fn ->
        object = "0123456789"
        Application.put_env(:gsmlg_storage, :storage_test_object, object)
        file = insert_file(%{size: byte_size(object), s3_key: "test/attachment/range.txt"})

        assert {:ok, "2345"} = Storage.read_range(file, 2, 5)
        assert_receive {:s3_get, ["bytes=2-5"]}

        assert {:ok, "67"} = Storage.read_range(file.id, 6, 7)
        assert_receive {:s3_get, ["bytes=6-7"]}
      end)
    end

    test "returns explicit errors for invalid or out-of-bounds ranges" do
      file = %StorageFile{size: 10, s3_key: "test/attachment/range.txt"}

      assert {:error, :invalid_range} = Storage.read_range(file, "0", 1)
      assert {:error, :invalid_range} = Storage.read_range(file, -1, 1)
      assert {:error, :invalid_range} = Storage.read_range(file, 2, 1)
      assert {:error, :range_out_of_bounds} = Storage.read_range(file, 0, 10)
      assert {:error, :range_out_of_bounds} = Storage.read_range(file, 10, 10)
      assert {:error, :invalid_id} = Storage.read_range("not-a-uuid", 0, 1)
      assert {:error, :invalid_file} = Storage.read_range(123, 0, 1)
      assert {:error, :invalid_file} = Storage.read_range(nil, 0, 1)
    end

    test "rejects ranges for zero-byte files without contacting S3" do
      with_s3_stub(fn ->
        file = %StorageFile{size: 0, s3_key: "test/attachment/empty.txt"}

        assert {:error, :range_out_of_bounds} = Storage.read_range(file, 0, 0)
        refute_received {:s3_get, _headers}
      end)
    end
  end

  describe "delete/1" do
    test "soft-deletes a file" do
      file = insert_file()
      assert {:ok, deleted} = Storage.delete(file)
      assert deleted.status == "deleted"

      # Should not appear in get_active
      assert nil == Storage.get_active(file.id)

      # Should still appear in get
      assert %StorageFile{status: "deleted"} = Storage.get(file.id)
    end

    test "delete by ID" do
      file = insert_file()
      assert {:ok, _} = Storage.delete(file.id)
      assert nil == Storage.get_active(file.id)
    end

    test "returns error for non-existent ID" do
      assert {:error, :not_found} = Storage.delete(Ecto.UUID.generate())
    end
  end

  describe "list/1" do
    test "returns paginated results" do
      for i <- 1..5, do: insert_file(%{filename: "file#{i}.jpg"})

      result = Storage.list(page_size: 2, page: 1)
      assert result.total == 5
      assert length(result.files) == 2
      assert result.total_pages == 3
    end

    test "filters by tenant" do
      insert_file(%{tenant: "alpha"})
      insert_file(%{tenant: "beta"})

      result = Storage.list(tenant: "alpha")
      assert result.total == 1
      assert hd(result.files).tenant == "alpha"
    end

    test "filters by type" do
      insert_file(%{type: "avatar"})
      insert_file(%{type: "document"})

      result = Storage.list(type: "avatar")
      assert result.total == 1
      assert hd(result.files).type == "avatar"
    end

    test "searches by filename" do
      insert_file(%{filename: "photo.jpg"})
      insert_file(%{filename: "document.pdf"})

      result = Storage.list(search: "photo")
      assert result.total == 1
      assert hd(result.files).filename == "photo.jpg"
    end

    test "defaults to active status" do
      insert_file(%{status: "active"})
      insert_file(%{status: "deleted"})

      result = Storage.list()
      assert result.total == 1
    end
  end

  describe "stats/1" do
    test "returns correct totals" do
      insert_file(%{size: 100, type: "avatar"})
      insert_file(%{size: 200, type: "avatar"})
      insert_file(%{size: 300, type: "document"})
      insert_file(%{size: 50, status: "deleted"})

      stats = Storage.stats()
      assert stats.total_files == 3
      assert Decimal.equal?(Decimal.new(600), stats.total_size)
      assert length(stats.by_type) == 2
    end

    test "filters by tenant" do
      insert_file(%{tenant: "alpha", size: 100})
      insert_file(%{tenant: "beta", size: 200})

      stats = Storage.stats("alpha")
      assert stats.total_files == 1
      assert Decimal.equal?(Decimal.new(100), stats.total_size)
    end
  end

  describe "stream_variant/2" do
    test "returns error for missing variant" do
      file = %StorageFile{variants: %{}}
      assert {:error, :variant_not_found} = Storage.stream_variant(file, "thumb")
    end

    test "returns error for nil variants" do
      file = %StorageFile{variants: nil}
      assert {:error, :variant_not_found} = Storage.stream_variant(file, "thumb")
    end
  end

  describe "purge/1" do
    test "rejects non-deleted files" do
      file = %StorageFile{status: "active"}
      assert {:error, :not_deleted} = Storage.purge(file)
    end

    test "deletes variants and the original before removing the S3 manifest" do
      with_s3_stub(fn ->
        variant_key = "test/attachment/variant-thumb.jpg"
        original_key = "test/attachment/original.jpg"

        file =
          insert_file(%{
            status: "deleted",
            s3_key: original_key,
            variants: %{"thumb" => %{"s3_key" => variant_key}}
          })

        stale_file = %{file | variants: %{}}

        assert {:ok, %StorageFile{id: id}} = Storage.purge(stale_file)
        assert id == file.id
        assert nil == Storage.get(file.id)

        assert_receive {:s3_delete, variant_path}
        assert String.ends_with?(variant_path, variant_key)
        assert_receive {:s3_delete, original_path}
        assert String.ends_with?(original_path, original_key)
      end)
    end

    test "converges when a later object deletion fails and the purge is retried" do
      with_s3_stub(fn ->
        variant_key = "test/attachment/variant-thumb.jpg"
        original_key = "test/attachment/original-failure.jpg"
        Application.put_env(:gsmlg_storage, :storage_test_delete_failure_key, original_key)

        file =
          insert_file(%{
            status: "deleted",
            s3_key: original_key,
            variants: %{"thumb" => %{"s3_key" => variant_key}}
          })

        assert {:error, _reason} = Storage.purge(file)
        assert %StorageFile{status: "deleted"} = Storage.get(file.id)

        assert_receive {:s3_delete, variant_path}
        assert String.ends_with?(variant_path, variant_key)
        assert_receive {:s3_delete, original_path}
        assert String.ends_with?(original_path, original_key)

        Application.delete_env(:gsmlg_storage, :storage_test_delete_failure_key)

        assert {:ok, %StorageFile{id: id}} = Storage.purge(Storage.get(file.id))
        assert id == file.id
        assert nil == Storage.get(file.id)

        assert_receive {:s3_delete, retried_variant_path}
        assert String.ends_with?(retried_variant_path, variant_key)
        assert_receive {:s3_delete, retried_original_path}
        assert String.ends_with?(retried_original_path, original_key)
      end)
    end

    test "retains the deleted manifest when metadata deletion fails and converges on retry" do
      with_s3_stub(fn ->
        file = insert_file(%{status: "deleted"})
        Application.put_env(:gsmlg_storage, :catalog_s3_client, FailingCatalogClient)
        Process.put({FailingCatalogClient, :failure}, :delete)

        assert {:error, :manifest_delete_failed} = Storage.purge(file)
        assert %StorageFile{status: "deleted"} = Storage.get(file.id)
        Process.delete({FailingCatalogClient, :failure})

        assert {:ok, %StorageFile{}} = Storage.purge(file)
        assert Storage.get(file.id) == nil
      end)
    end

    test "stops at the first failed variant deletion" do
      with_s3_stub(fn ->
        variant_key = "test/attachment/variant-failure.jpg"
        original_key = "test/attachment/original-not-attempted.jpg"
        Application.put_env(:gsmlg_storage, :storage_test_delete_failure_key, variant_key)

        file =
          insert_file(%{
            status: "deleted",
            s3_key: original_key,
            variants: %{"thumb" => %{"s3_key" => variant_key}}
          })

        assert {:error, _reason} = Storage.purge(file)
        assert %StorageFile{status: "deleted"} = Storage.get(file.id)

        assert_receive {:s3_delete, variant_path}
        assert String.ends_with?(variant_path, variant_key)
        refute_received {:s3_delete, _path}
      end)
    end
  end

  describe "create_folder/2" do
    test "creates a folder marker" do
      with_s3_stub(fn ->
        assert {:ok, folder} = Storage.create_folder("my-tenant", "images")
        assert folder.tenant == "my-tenant"
        assert folder.type == "images"
      end)
    end

    test "creates a tenant-only folder" do
      with_s3_stub(fn ->
        assert {:ok, folder} = Storage.create_folder("my-tenant")
        assert folder.tenant == "my-tenant"
        assert is_nil(folder.type)
      end)
    end

    test "creating the same folder marker is idempotent" do
      with_s3_stub(fn ->
        assert {:ok, _} = Storage.create_folder("my-tenant", "images")
        assert {:ok, _} = Storage.create_folder("my-tenant", "images")
      end)
    end
  end

  describe "folder_tree/0" do
    test "returns hierarchical tree from files" do
      with_s3_stub(fn ->
        insert_file(%{tenant: "alpha", type: "avatar"})
        insert_file(%{tenant: "alpha", type: "document"})
        insert_file(%{tenant: "beta", type: "avatar"})

        tree = Storage.folder_tree()
        assert length(tree) == 2

        alpha = Enum.find(tree, &(&1.tenant == "alpha"))
        assert length(alpha.types) == 2
      end)
    end

    test "includes explicit folders without files" do
      with_s3_stub(fn ->
        Storage.create_folder("empty-tenant", "photos")

        tree = Storage.folder_tree()
        empty = Enum.find(tree, &(&1.tenant == "empty-tenant"))
        assert empty != nil
        assert length(empty.types) == 1
        assert hd(empty.types).type == "photos"
      end)
    end
  end

  describe "delete_folder/4" do
    test "soft-deletes all files in tenant" do
      with_s3_stub(fn ->
        insert_file(%{tenant: "doomed"})
        insert_file(%{tenant: "doomed"})
        insert_file(%{tenant: "safe"})

        assert {:ok, _} = Storage.delete_folder("doomed")
        assert Storage.list(tenant: "doomed").total == 0
        assert Storage.list(tenant: "safe").total == 1
      end)
    end

    test "soft-deletes files in tenant+type" do
      with_s3_stub(fn ->
        insert_file(%{tenant: "t", type: "avatar"})
        insert_file(%{tenant: "t", type: "document"})

        assert {:ok, _} = Storage.delete_folder("t", "avatar")
        assert Storage.list(tenant: "t", type: "avatar").total == 0
        assert Storage.list(tenant: "t", type: "document").total == 1
      end)
    end

    test "rejects month without year" do
      with_s3_stub(fn ->
        assert {:error, :month_requires_year} = Storage.delete_folder("t", "avatar", nil, 3)
      end)
    end
  end

  describe "get_config/0 and update_config/1" do
    test "returns default config when none saved" do
      config = Storage.get_config()
      assert %GSMLG.Storage.StorageConfig{} = config
    end

    test "saves and loads config" do
      assert {:ok, config} =
               Storage.update_config(%{s3_bucket: "test-bucket", max_file_size: 1024})

      assert config.s3_bucket == "test-bucket"
      assert config.max_file_size == 1024

      loaded = Storage.get_config()
      assert loaded.s3_bucket == "test-bucket"
    end
  end
end
