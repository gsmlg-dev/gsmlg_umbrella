defmodule GSMLG.Web.FileControllerTest do
  use GSMLG.Web.ConnCase

  defmodule S3Stub do
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    Plug.Router.get "/*path" do
      data =
        if String.starts_with?(conn.request_path, "/controller-test/"),
          do: String.duplicate("x", 1024),
          else: "wrong bucket"

      send_resp(conn, 200, data)
    end

    match(_, do: send_resp(conn, 404, ""))
  end

  alias GSMLG.Storage.{StorageFile, TestCatalogClient}

  defmodule SwitchingCatalogClient do
    alias GSMLG.Storage.TestCatalogClient

    def get_object(backend, key) do
      result = TestCatalogClient.get_object(backend, key)
      Application.put_env(:gsmlg_storage, :s3_bucket, "other-bucket")
      result
    end
  end

  setup do
    TestCatalogClient.setup!()
    keys = [:s3_endpoint, :s3_bucket]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: S3Stub, port: port, startup_log: false})
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_bucket, "controller-test")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    :ok
  end

  @valid_attrs %{
    tenant: "test",
    type: "attachment",
    filename: "test.jpg",
    s3_key: "test/attachment/2026/03/test-uuid.jpg",
    content_type: "image/jpeg",
    size: 1024,
    checksum: "abc123def456",
    metadata: %{},
    variants: %{
      "thumb" => %{
        "s3_key" => "test/attachment/2026/03/test-uuid_thumb.webp",
        "size" => 512,
        "content_type" => "image/webp"
      }
    },
    status: "active",
    uploaded_by: "test"
  }

  defp insert_file(attrs \\ %{}) do
    %StorageFile{}
    |> StorageFile.changeset(Map.merge(@valid_attrs, attrs))
    |> TestCatalogClient.insert_file!()
  end

  describe "GET /files/:id" do
    test "returns 404 for non-existent file", %{conn: conn} do
      conn = get(conn, "/files/#{Ecto.UUID.generate()}")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for invalid UUID", %{conn: conn} do
      conn = get(conn, "/files/not-a-uuid")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for deleted file", %{conn: conn} do
      file = insert_file(%{status: "deleted"})
      conn = get(conn, "/files/#{file.id}")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for processing file", %{conn: conn} do
      file = insert_file(%{status: "processing"})
      conn = get(conn, "/files/#{file.id}")
      assert response(conn, 404) =~ "Not Found"
    end
  end

  describe "GET /files/:id/v/:variant" do
    test "returns 404 for non-existent file", %{conn: conn} do
      conn = get(conn, "/files/#{Ecto.UUID.generate()}/v/thumb")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for non-existent variant", %{conn: conn} do
      file = insert_file(%{variants: %{}})

      conn = get(conn, "/files/#{file.id}/v/nonexistent")
      assert response(conn, 404) =~ "Not Found"
    end

    test "returns 404 for file with nil variants", %{conn: conn} do
      file = insert_file(%{variants: nil})

      conn = get(conn, "/files/#{file.id}/v/thumb")
      assert response(conn, 404) =~ "Not Found"
    end
  end

  test "keeps manifest and original bytes on the captured bucket during configuration changes", %{
    conn: conn
  } do
    file = insert_file()
    Application.put_env(:gsmlg_storage, :catalog_s3_client, SwitchingCatalogClient)
    conn = get(conn, "/files/#{file.id}")
    assert response(conn, 200) == String.duplicate("x", 1024)
    assert Application.get_env(:gsmlg_storage, :s3_bucket) == "other-bucket"
  end

  test "keeps variant bytes on the manifest's captured bucket during configuration changes", %{
    conn: conn
  } do
    file = insert_file()
    Application.put_env(:gsmlg_storage, :catalog_s3_client, SwitchingCatalogClient)
    conn = get(conn, "/files/#{file.id}/v/thumb")
    assert response(conn, 200) == String.duplicate("x", 1024)
    assert Application.get_env(:gsmlg_storage, :s3_bucket) == "other-bucket"
  end

  describe "Range header parsing" do
    test "returns 206 with partial content for valid Range header", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("range", "bytes=0-99")
        |> get("/files/#{file.id}")

      assert response(conn, 206) == String.duplicate("x", 100)
      assert get_resp_header(conn, "content-range") == ["bytes 0-99/1024"]
    end

    test "returns 416 for out-of-range request", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("range", "bytes=999999999-")
        |> get("/files/#{file.id}")

      assert conn.status == 416
      assert get_resp_header(conn, "content-range") == ["bytes */1024"]
    end
  end

  describe "ETag / 304 handling" do
    test "returns 304 when If-None-Match matches checksum", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("if-none-match", ~s("#{file.checksum}"))
        |> get("/files/#{file.id}")

      assert conn.status == 304
      assert get_resp_header(conn, "etag") == [~s("#{file.checksum}")]
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    end

    test "does not return 304 when If-None-Match does not match", %{conn: conn} do
      file = insert_file()

      conn =
        conn
        |> put_req_header("if-none-match", ~s("wrong-checksum"))
        |> get("/files/#{file.id}")

      assert response(conn, 200) == String.duplicate("x", 1024)
      refute conn.status == 304
    end
  end
end
