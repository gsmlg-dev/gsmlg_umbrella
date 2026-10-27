defmodule GSMLG.Storage.CatalogHTTPTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.{Catalog, S3Client, StorageFile}

  defmodule ObjectStore do
    import Plug.Conn
    def init(objects), do: objects

    def call(%{method: "PUT"} = conn, objects) do
      {:ok, bytes, conn} = read_body(conn)
      :ets.insert(objects, {conn.request_path, bytes})
      send_resp(conn, 200, "")
    end

    def call(%{method: "GET"} = conn, objects) do
      [{_, bytes}] = :ets.lookup(objects, conn.request_path)
      conn |> put_resp_content_type("application/json") |> send_resp(200, bytes)
    end
  end

  test "the real signed S3 transport preserves JSON manifest bytes" do
    objects = :ets.new(:http_catalog_manifests, [:set, :public])
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Gaoxy.HTTP, plug: {ObjectStore, objects}, port: port})

    {:ok, backend} =
      S3Client.capture_backend(
        s3_bucket: "catalog-http",
        s3_endpoint: "http://127.0.0.1:#{port}",
        s3_access_key_id: "test",
        s3_secret_access_key: "test-secret"
      )

    file = %StorageFile{
      tenant: "test",
      type: "attachment",
      filename: "file.txt",
      s3_key: "test/file.txt",
      content_type: "text/plain",
      size: 4,
      metadata: %{"label" => "完整 JSON"}
    }

    assert {:ok, saved} = Catalog.save(file, backend: backend, client: S3Client)
    assert {:ok, fetched} = Catalog.fetch(saved.id, backend: backend, client: S3Client)
    assert fetched.id == saved.id
    assert fetched.metadata == saved.metadata
    json = "  {\"count\": 1}\n"
    assert :ok = S3Client.put_object(backend, "external.json", json, "application/json")
    assert {:ok, ^json} = S3Client.get_object(backend, "external.json")
  end
end
