defmodule GSMLG.Storage.CatalogTest do
  use ExUnit.Case, async: true
  alias GSMLG.Storage.{Catalog, S3Client, StorageFile}

  defmodule HTTPClient do
    @behaviour AWS.HTTPClient
    def request(method, url, body, _headers, options) do
      store = options[:store]
      key = URI.parse(url).path |> String.replace_prefix("/catalog-test/", "") |> URI.decode()

      case method do
        :put ->
          Agent.update(store, &Map.put(&1, key, IO.iodata_to_binary(body)))
          {:ok, %{status_code: 200, headers: [], body: ""}}

        :get ->
          case Agent.get(store, &Map.fetch(&1, key)) do
            {:ok, data} -> {:ok, %{status_code: 200, headers: [], body: data}}
            :error -> {:ok, %{status_code: 404, headers: [], body: ""}}
          end

        :delete ->
          Agent.update(store, &Map.delete(&1, key))
          {:ok, %{status_code: 204, headers: [], body: ""}}
      end
    end
  end

  setup do
    store = start_supervised!({Agent, fn -> %{} end})

    {:ok, backend} =
      S3Client.capture_backend(
        s3_bucket: "catalog-test",
        s3_endpoint: "http://s3.example.test",
        s3_access_key_id: "test",
        s3_secret_access_key: "secret"
      )

    backend = %{
      backend
      | client: AWS.Client.put_http_client(backend.client, {HTTPClient, [store: store]})
    }

    %{backend: backend, store: store}
  end

  test "preserves legacy identity and complete metadata in S3 without a database", %{
    backend: backend
  } do
    id = Ecto.UUID.generate()

    file = %StorageFile{
      id: id,
      tenant: "gaonote",
      type: "attachment",
      filename: "original.png",
      s3_key: "legacy/2026/a-different-uuid.png",
      size: 12,
      content_type: "image/png",
      checksum: String.duplicate("a", 64),
      metadata: %{"note_id" => "note"},
      variants: %{"thumb" => %{"s3_key" => "legacy/thumb.png"}}
    }

    assert {:ok, saved} = Catalog.save(file, backend: backend)
    assert {:ok, fetched} = Catalog.fetch(id, backend: backend)
    assert fetched.id == id
    assert fetched.s3_key == file.s3_key
    assert fetched.metadata == file.metadata
    assert fetched.variants == file.variants
    assert fetched.inserted_at == saved.inserted_at
    assert fetched.checksum == file.checksum
  end

  test "persists processing and deleted states and removes only the descriptor on purge", %{
    backend: backend,
    store: store
  } do
    file = %StorageFile{
      tenant: "test",
      type: "attachment",
      filename: "upload.txt",
      s3_key: "test/upload.txt",
      size: 4,
      content_type: "text/plain",
      status: "processing",
      metadata: %{"upload_expires_at" => "2026-10-14T09:00:00Z"}
    }

    assert {:ok, file} = Catalog.save(file, backend: backend)
    assert {:ok, %{status: "processing"}} = Catalog.fetch(file.id, backend: backend)

    assert {:ok, deleted} =
             Catalog.update(StorageFile.status_changeset(file, %{status: "deleted"}),
               backend: backend
             )

    assert {:ok, %{status: "deleted"}} = Catalog.fetch(file.id, backend: backend)
    assert {:ok, ^deleted} = Catalog.delete(deleted, backend: backend)
    assert Agent.get(store, & &1) == %{}
    assert {:error, :not_found} = Catalog.fetch(file.id, backend: backend)
  end

  test "rejects corrupted manifests rather than reading a database fallback", %{
    backend: backend,
    store: store
  } do
    id = Ecto.UUID.generate()
    Agent.update(store, &Map.put(&1, ".gsmlg-storage/objects/#{id}.json", "{broken"))
    assert {:error, :invalid_storage_manifest} = Catalog.fetch(id, backend: backend)
    assert {:error, :invalid_id} = Catalog.fetch("not-an-id", backend: backend)
  end

  test "rejects malformed variant descriptors and retains the corrupt manifest", %{
    backend: backend,
    store: store
  } do
    file = %StorageFile{
      tenant: "test",
      type: "attachment",
      filename: "file.txt",
      s3_key: "test/file.txt",
      size: 4,
      content_type: "text/plain"
    }

    assert {:ok, saved} = Catalog.save(file, backend: backend)
    key = ".gsmlg-storage/objects/#{saved.id}.json"

    Agent.update(store, fn objects ->
      Map.update!(objects, key, fn data ->
        data |> JSON.decode!() |> Map.put("variants", %{"thumb" => "broken"}) |> JSON.encode!()
      end)
    end)

    corrupted = Agent.get(store, &Map.fetch!(&1, key))
    assert {:error, :invalid_storage_manifest} = Catalog.fetch(saved.id, backend: backend)
    assert Agent.get(store, &Map.fetch!(&1, key)) == corrupted

    assert {:error, :invalid_storage_manifest} =
             Catalog.save(%{saved | variants: %{"thumb" => 5}}, backend: backend)

    assert Agent.get(store, &Map.fetch!(&1, key)) == corrupted
  end
end
