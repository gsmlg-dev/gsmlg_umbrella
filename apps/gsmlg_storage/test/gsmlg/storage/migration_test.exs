defmodule GSMLG.Storage.MigrationTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage.{Catalog, Migration, StorageFile, StorageFolder, TestCatalogClient}

  defmodule ObjectStore do
    import Plug.Conn
    def init(objects), do: objects

    def call(%{method: "HEAD"} = conn, objects) do
      case :ets.lookup(objects, conn.request_path) do
        [{_, bytes}] ->
          conn
          |> put_resp_header("content-length", Integer.to_string(byte_size(bytes)))
          |> send_resp(200, "")

        [] ->
          send_resp(conn, 404, "")
      end
    end

    def call(%{method: "PUT"} = conn, objects) do
      {:ok, bytes, conn} = read_body(conn)
      :ets.insert(objects, {conn.request_path, bytes})
      send_resp(conn, 200, "")
    end

    def call(%{method: "GET"} = conn, objects) do
      case :ets.lookup(objects, conn.request_path) do
        [{_, bytes}] -> send_resp(conn, 200, bytes)
        [] -> send_resp(conn, 404, "")
      end
    end
  end

  setup do
    TestCatalogClient.setup!()
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Repo.query!("CREATE TEMP TABLE storage_files (LIKE public.storage_files INCLUDING ALL)")
    Repo.query!("CREATE TEMP TABLE storage_folders (LIKE public.storage_folders INCLUDING ALL)")
    Repo.query!("CREATE TEMP TABLE storage_config (LIKE public.storage_config INCLUDING ALL)")
    Repo.query!("SET LOCAL search_path TO pg_temp, public")

    objects = :ets.new(:catalog_export_objects, [:set, :public])
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    start_supervised!({Gaoxy.HTTP, plug: {ObjectStore, objects}, port: port})

    config = %{s3_endpoint: "http://127.0.0.1:#{port}", s3_bucket: "export-test"}

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    %{objects: objects}
  end

  test "export preserves UUIDs, keys, timestamps and SQL data and resumes without overwriting manifests",
       %{objects: objects} do
    active = legacy_file("active")
    deleted = legacy_file("deleted")
    :ets.insert(objects, {"/export-test/#{active.s3_key}", "legacy"})
    folder = Repo.insert!(%StorageFolder{tenant: "legacy", type: "document"})

    assert {:ok, %{exported: 2, skipped: 0, folders: 1}} = Migration.export_catalog()

    for original <- [active, deleted] do
      assert {:ok, exported} = Catalog.fetch(original.id)

      for field <- [:id, :s3_key, :status, :inserted_at, :updated_at, :metadata, :checksum] do
        assert Map.fetch!(exported, field) == Map.fetch!(original, field)
      end

      assert Repo.get!(StorageFile, original.id) == original
    end

    assert Repo.get!(StorageFolder, folder.id) == folder

    assert :ets.lookup(objects, "/export-test/legacy/document/") == [
             {"/export-test/legacy/document/", ""}
           ]

    {:ok, migrated} = Catalog.fetch(active.id)
    assert {:ok, _} = Catalog.save(%{migrated | metadata: %{"changed_after_export" => true}})
    assert {:ok, %{exported: 0, skipped: 2, folders: 1}} = Migration.export_catalog()
    assert {:ok, %{metadata: %{"changed_after_export" => true}}} = Catalog.fetch(active.id)
  end

  test "a conflicting migrated identity stops export and preserves both catalogs" do
    original = legacy_file("deleted")
    assert {:ok, migrated} = Catalog.save(%{original | s3_key: "new/location.txt"})
    assert {:error, %{file_id: id, reason: :manifest_key_conflict}} = Migration.export_catalog()
    assert id == original.id
    assert Repo.get!(StorageFile, original.id) == original
    assert {:ok, retained} = Catalog.fetch(original.id)
    assert Map.delete(retained, :__meta__) == Map.delete(migrated, :__meta__)
  end

  test "missing active bytes stop export without publishing a manifest" do
    original = legacy_file("active")
    assert {:error, %{file_id: id}} = Migration.export_catalog()
    assert id == original.id
    assert {:error, :not_found} = Catalog.fetch(id)
    assert Repo.get!(StorageFile, id) == original
  end

  test "different active object size stops export without publishing a manifest", %{
    objects: objects
  } do
    original = legacy_file("active")
    :ets.insert(objects, {"/export-test/#{original.s3_key}", "wrong size"})

    assert {:error, %{file_id: id, reason: :legacy_object_size_mismatch}} =
             Migration.export_catalog()

    assert id == original.id
    assert {:error, :not_found} = Catalog.fetch(id)
    assert Repo.get!(StorageFile, id) == original
  end

  test "automatic export publishes a versioned checkpoint only after success", %{objects: objects} do
    original = legacy_file("active")
    :ets.insert(objects, {"/export-test/#{original.s3_key}", "legacy"})
    assert :ok = Migration.export_if_needed()
    [{_, body}] = :ets.lookup(objects, "/export-test/.gsmlg-storage/migrations/catalog-v1.json")
    assert %{"version" => 1, "exported" => 1, "skipped" => 0, "folders" => 0} = JSON.decode!(body)
    assert {:ok, _} = Catalog.fetch(original.id)
    assert :ok = Migration.export_if_needed()

    assert :ets.lookup(objects, "/export-test/.gsmlg-storage/migrations/catalog-v1.json") == [
             {"/export-test/.gsmlg-storage/migrations/catalog-v1.json", body}
           ]
  end

  test "a malformed checkpoint cannot bypass legacy export validation", %{objects: objects} do
    legacy_file("deleted")
    :ets.insert(objects, {"/export-test/.gsmlg-storage/migrations/catalog-v1.json", "{broken"})
    assert {:error, :invalid_storage_migration_checkpoint} = Migration.export_if_needed()
    assert TestCatalogClient.count() == 0
  end

  test "a failed export never publishes a checkpoint", %{objects: objects} do
    original = legacy_file("active")
    assert {:error, %{file_id: id}} = Migration.export_if_needed()
    assert id == original.id
    assert :ets.lookup(objects, "/export-test/.gsmlg-storage/migrations/catalog-v1.json") == []
  end

  test "folder export cannot overwrite a nonempty S3 object", %{objects: objects} do
    Repo.insert!(%StorageFolder{tenant: "legacy", type: "document"})
    :ets.insert(objects, {"/export-test/legacy/document/", "retain these bytes"})

    assert {:error, %{folder: "legacy/document/", reason: :legacy_folder_key_conflict}} =
             Migration.export_catalog()

    assert :ets.lookup(objects, "/export-test/legacy/document/") == [
             {"/export-test/legacy/document/", "retain these bytes"}
           ]
  end

  defp legacy_file(status) do
    Repo.insert!(%StorageFile{
      id: Ecto.UUID.generate(),
      tenant: "legacy",
      type: "document",
      filename: "legacy.txt",
      s3_key: "legacy/#{Ecto.UUID.generate()}.txt",
      content_type: "text/plain",
      size: 6,
      checksum: "legacy-checksum",
      metadata: %{"historical" => true},
      variants: %{},
      status: status,
      inserted_at: ~U[2020-01-02 03:04:05.000000Z],
      updated_at: ~U[2021-02-03 04:05:06.000000Z]
    })
  end
end
