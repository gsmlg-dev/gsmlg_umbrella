defmodule GSMLG.StorageTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(GSMLG.Repo)
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
    |> Repo.insert!()
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
      deleted = insert_file(%{status: "deleted"})

      assert %StorageFile{} = Storage.get_active(file.id)
      assert nil == Storage.get_active(deleted.id)
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
  end

  describe "create_folder/2" do
    test "creates a folder record" do
      assert {:ok, folder} = Storage.create_folder("my-tenant", "images")
      assert folder.tenant == "my-tenant"
      assert folder.type == "images"
    end

    test "creates a tenant-only folder" do
      assert {:ok, folder} = Storage.create_folder("my-tenant")
      assert folder.tenant == "my-tenant"
      assert is_nil(folder.type)
    end

    test "rejects duplicate folder" do
      assert {:ok, _} = Storage.create_folder("my-tenant", "images")
      assert {:error, _} = Storage.create_folder("my-tenant", "images")
    end
  end

  describe "folder_tree/0" do
    test "returns hierarchical tree from files" do
      insert_file(%{tenant: "alpha", type: "avatar"})
      insert_file(%{tenant: "alpha", type: "document"})
      insert_file(%{tenant: "beta", type: "avatar"})

      tree = Storage.folder_tree()
      assert length(tree) == 2

      alpha = Enum.find(tree, &(&1.tenant == "alpha"))
      assert length(alpha.types) == 2
    end

    test "includes explicit folders without files" do
      Storage.create_folder("empty-tenant", "photos")

      tree = Storage.folder_tree()
      empty = Enum.find(tree, &(&1.tenant == "empty-tenant"))
      assert empty != nil
      assert length(empty.types) == 1
      assert hd(empty.types).type == "photos"
    end
  end

  describe "delete_folder/4" do
    test "soft-deletes all files in tenant" do
      insert_file(%{tenant: "doomed"})
      insert_file(%{tenant: "doomed"})
      insert_file(%{tenant: "safe"})

      assert {:ok, _} = Storage.delete_folder("doomed")
      assert Storage.list(tenant: "doomed").total == 0
      assert Storage.list(tenant: "safe").total == 1
    end

    test "soft-deletes files in tenant+type" do
      insert_file(%{tenant: "t", type: "avatar"})
      insert_file(%{tenant: "t", type: "document"})

      assert {:ok, _} = Storage.delete_folder("t", "avatar")
      assert Storage.list(tenant: "t", type: "avatar").total == 0
      assert Storage.list(tenant: "t", type: "document").total == 1
    end

    test "rejects month without year" do
      assert {:error, :month_requires_year} = Storage.delete_folder("t", "avatar", nil, 3)
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
