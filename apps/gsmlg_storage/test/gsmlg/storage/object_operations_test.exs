defmodule GSMLG.Storage.ObjectOperationsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, S3Client, StorageFile, TestCatalogClient}

  defmodule ObjectStore do
    import Plug.Conn
    def init(opts), do: opts

    def call(conn, %{pid: pid, objects: objects}) do
      send(pid, {conn.method, conn.request_path})

      case conn.method do
        "PUT" ->
          {:ok, bytes, conn} = read_body(conn)

          if get_req_header(conn, "if-none-match") == ["*"] and
               :ets.member(objects, conn.request_path) do
            send_resp(conn, 412, "")
          else
            :ets.insert(objects, {conn.request_path, bytes})
            send_resp(conn, 200, "")
          end

        "HEAD" ->
          case :ets.lookup(objects, conn.request_path) do
            [{_, bytes}] ->
              conn
              |> put_resp_header("content-length", to_string(byte_size(bytes)))
              |> send_resp(200, "")

            [] ->
              send_resp(conn, 404, "")
          end

        "DELETE" ->
          :ets.delete(objects, conn.request_path)
          send_resp(conn, 204, "")
      end
    end
  end

  defmodule CommittedThenFailedCatalogClient do
    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate list_objects(backend), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def put_object(backend, key, data, content_type) do
      attrs = JSON.decode!(data)

      if attrs["status"] == "active" do
        # Simulate a successfully persisted active manifest before its caller
        # sees a failure. Compensation must load the durable state again.
        variants = %{"thumb" => %{"s3_key" => "retained/thumb.png"}}

        :ok =
          TestCatalogClient.put_object(
            backend,
            key,
            JSON.encode!(Map.put(attrs, "variants", variants)),
            content_type
          )

        raise "commit failed after S3 write"
      else
        TestCatalogClient.put_object(backend, key, data, content_type)
      end
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GSMLG.Repo)
    TestCatalogClient.setup!()
    keys = [:s3_bucket, :s3_endpoint]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    objects = :ets.new(:object_operation_bytes, [:set, :public])

    start_supervised!(
      {Bandit,
       plug: {ObjectStore, %{pid: self(), objects: objects}}, port: port, startup_log: false}
    )

    Application.put_env(:gsmlg_storage, :s3_bucket, "objects-test")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    %{backend_id: S3Client.current_backend_id(), objects: objects}
  end

  test "deletes an untracked exact S3 key without a SQL catalog", %{backend_id: id} do
    key = "外部上传/space + percent%.txt"
    assert {:ok, ^key} = Storage.delete_object(key, id)
    assert_receive {"DELETE", path}
    assert URI.decode(path) == "/objects-test/" <> key
    assert TestCatalogClient.count() == 0
  end

  test "creates a real empty folder marker", %{backend_id: id} do
    assert {:ok, "外部文件/empty/"} = Storage.create_object_folder("外部文件/empty", id)
    assert_receive {"PUT", path}
    assert URI.decode(path) == "/objects-test/外部文件/empty/"
  end

  test "folder creation retains existing nonempty trailing-slash objects", %{
    backend_id: id,
    objects: objects
  } do
    :ets.insert(objects, {"/objects-test/occupied/", "retain this file"})
    assert {:error, :folder_key_conflict} = Storage.create_object_folder("occupied", id)

    assert :ets.lookup(objects, "/objects-test/occupied/") == [
             {"/objects-test/occupied/", "retain this file"}
           ]
  end

  test "creating an existing empty marker is idempotent", %{backend_id: id, objects: objects} do
    :ets.insert(objects, {"/objects-test/empty/", ""})
    assert {:ok, "empty/"} = Storage.create_object_folder("empty", id)
    assert :ets.lookup(objects, "/objects-test/empty/") == [{"/objects-test/empty/", ""}]
  end

  test "upload exception compensation retains the latest durable variants" do
    Application.put_env(:gsmlg_storage, :catalog_s3_client, CommittedThenFailedCatalogClient)

    assert_raise RuntimeError, "commit failed after S3 write", fn ->
      Storage.upload({"file.txt", "text"}, "test", "attachment", variants: [])
    end

    assert {:ok,
            [%{status: "deleted", variants: %{"thumb" => %{"s3_key" => "retained/thumb.png"}}}]} =
             Catalog.list()
  end

  test "refuses internal manifest deletion and creation", %{backend_id: id} do
    assert {:error, :reserved_storage_key} =
             Storage.delete_object(".gsmlg-storage/objects/file.json", id)

    assert {:error, :reserved_storage_key} = Storage.create_object_folder(".gsmlg-storage", id)
    refute_receive {"DELETE", _}
    refute_receive {"PUT", _}
  end

  test "stale snapshot cannot delete, create or upload in the replacement bucket", %{
    backend_id: id
  } do
    Application.put_env(:gsmlg_storage, :s3_bucket, "replacement")
    assert {:error, :backend_changed} = Storage.delete_object("file.txt", id)
    assert {:error, :backend_changed} = Storage.create_object_folder("folder", id)

    assert {:error, :backend_changed} =
             Storage.upload({"file.txt", "text"}, "test", "attachment", backend_id: id)

    refute_receive {"DELETE", _}
    refute_receive {"PUT", _}
    assert TestCatalogClient.count() == 0
  end

  test "deletes a managed original and all variants before dropping the S3 manifest", %{
    backend_id: id
  } do
    file = file(variants: %{"thumb" => %{"s3_key" => "managed/thumb.png"}})
    assert {:ok, "managed/original.txt"} = Storage.delete_object(file.s3_key, id)
    assert_receive {"DELETE", "/objects-test/managed/thumb.png"}
    assert_receive {"DELETE", "/objects-test/managed/original.txt"}
    assert {:error, :not_found} = Catalog.fetch(file.id)
  end

  test "deleting one managed variant retains the original and other variants", %{backend_id: id} do
    file =
      file(
        variants: %{
          "thumb" => %{"s3_key" => "managed/thumb.png"},
          "medium" => %{"s3_key" => "managed/medium.png"}
        }
      )

    assert {:ok, "managed/thumb.png"} = Storage.delete_object("managed/thumb.png", id)
    assert_receive {"DELETE", "/objects-test/managed/thumb.png"}
    refute_receive {"DELETE", "/objects-test/managed/original.txt"}
    assert {:ok, %{status: "active", variants: variants}} = Catalog.fetch(file.id)
    assert variants == %{"medium" => %{"s3_key" => "managed/medium.png"}}
  end

  test "browser deletion retains an attachment-owned original and variant", %{backend_id: id} do
    file = file(variants: %{"thumb" => %{"s3_key" => "managed/thumb.png"}})
    note = GSMLG.Repo.insert!(%GSMLG.GaoNote.Note{title: "Protected", content: "text"})

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: "protected-attachment",
      api_id: "protected-attachment",
      note_id: note.id,
      storage_file_id: file.id,
      path: "./file.txt",
      mime: "text/plain"
    })

    assert {:error, :file_referenced} = Storage.delete_object(file.s3_key, id)
    assert {:error, :file_referenced} = Storage.delete_object("managed/thumb.png", id)
    assert {:ok, %{status: "active"}} = Catalog.fetch(file.id)
    refute_receive {"DELETE", _}
  end

  defp file(attrs) do
    defaults = %{
      tenant: "test",
      type: "attachment",
      filename: "file.txt",
      s3_key: "managed/original.txt",
      content_type: "text/plain",
      size: 4,
      status: "active",
      metadata: %{}
    }

    %StorageFile{}
    |> StorageFile.changeset(Map.merge(defaults, Map.new(attrs)))
    |> TestCatalogClient.insert_file!()
  end
end
