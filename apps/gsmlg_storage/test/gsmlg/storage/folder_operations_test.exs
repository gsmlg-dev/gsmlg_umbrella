defmodule GSMLG.Storage.FolderOperationsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, StorageFile, TestCatalogClient}

  defmodule S3Stub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    delete "/*path" do
      send(
        Application.fetch_env!(:gsmlg_storage, :folder_test_pid),
        {:marker_delete, conn.request_path}
      )

      send_resp(conn, 204, "")
    end

    get "/*path" do
      send(
        Application.fetch_env!(:gsmlg_storage, :folder_test_pid),
        {:marker_list, conn.request_path}
      )

      key = if conn.request_path == "/folder-test", do: "marker-a%2F", else: "marker-b%2F"

      body =
        "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>" <>
          "<Contents><Key>#{key}</Key><Size>0</Size><LastModified>2026-10-14T00:00:00Z</LastModified></Contents></ListBucketResult>"

      send_resp(conn, 200, body)
    end
  end

  defmodule StaleCatalogClient do
    defdelegate list_objects(backend), to: TestCatalogClient
    defdelegate put_object(backend, key, data, content_type), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def get_object(backend, key) do
      case Process.delete({__MODULE__, :snapshot}) do
        nil -> TestCatalogClient.get_object(backend, key)
        snapshot -> {:ok, snapshot}
      end
    end
  end

  defmodule SwitchingCatalogClient do
    defdelegate get_object(backend, key), to: TestCatalogClient
    defdelegate put_object(backend, key, data, content_type), to: TestCatalogClient
    defdelegate delete_object(backend, key), to: TestCatalogClient

    def list_objects(backend) do
      result = TestCatalogClient.list_objects(backend)
      Application.put_env(:gsmlg_storage, :s3_bucket, "other-bucket")
      result
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    TestCatalogClient.setup!()
    keys = [:s3_endpoint, :s3_bucket, :folder_test_pid]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: S3Stub, port: port, startup_log: false})
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_bucket, "folder-test")
    Application.put_env(:gsmlg_storage, :folder_test_pid, self())

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    :ok
  end

  test "folder deletion keeps variants committed after the initial catalog snapshot" do
    file = manifest()
    {:ok, backend} = GSMLG.Storage.S3Client.capture_backend()
    {:ok, [object]} = TestCatalogClient.list_objects(backend)
    {:ok, stale_snapshot} = TestCatalogClient.get_object(backend, object.key)
    variants = %{"thumb" => %{"s3_key" => "newly-generated-thumb.png"}}

    assert {:ok, _file} =
             file |> StorageFile.variants_changeset(%{variants: variants}) |> Catalog.update()

    Application.put_env(:gsmlg_storage, :catalog_s3_client, StaleCatalogClient)
    Process.put({StaleCatalogClient, :snapshot}, stale_snapshot)

    assert {:ok, :ok} = Storage.delete_folder("from-a", "attachment", file.inserted_at.year)
    assert %StorageFile{status: "deleted", variants: ^variants} = Storage.get(file.id)
  end

  test "empty-folder deletion uses the captured bucket after runtime configuration changes" do
    Application.put_env(:gsmlg_storage, :catalog_s3_client, SwitchingCatalogClient)
    assert {:ok, :ok} = Storage.delete_folder("empty-folder")
    assert_receive {:marker_delete, "/folder-test/empty-folder/"}
    refute_receive {:marker_delete, "/other-bucket/empty-folder/"}
  end

  test "folder tree combines manifests and markers from the same captured bucket" do
    manifest()
    Application.put_env(:gsmlg_storage, :catalog_s3_client, SwitchingCatalogClient)
    tree = Storage.folder_tree()
    assert_receive {:marker_list, "/folder-test"}
    assert Enum.map(tree, & &1.tenant) == ["from-a", "marker-a"]
    refute_receive {:marker_list, "/other-bucket"}
  end

  defp manifest do
    %StorageFile{}
    |> StorageFile.changeset(%{
      tenant: "from-a",
      type: "attachment",
      filename: "file.txt",
      s3_key: "from-a/file.txt",
      content_type: "text/plain",
      size: 1,
      variants: %{}
    })
    |> TestCatalogClient.insert_file!()
  end
end
