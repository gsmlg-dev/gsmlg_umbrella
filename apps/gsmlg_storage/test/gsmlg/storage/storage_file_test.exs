defmodule GSMLG.Storage.StorageFileTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage.{StorageFile, Catalog, TestCatalogClient}

  setup do
    TestCatalogClient.setup!()
    :ok
  end

  test "persists validated metadata in an S3 manifest and keeps its stable identity" do
    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/object.jpg",
        content_type: "image/jpeg",
        size: 1024,
        metadata: %{"source" => "external"},
        variants: %{"thumb" => %{"s3_key" => "thumb.jpg"}}
      })
      |> TestCatalogClient.insert_file!()

    assert {:ok, fetched} = Catalog.fetch(file.id)
    assert fetched.id == file.id
    assert fetched.s3_key == file.s3_key
    assert fetched.metadata == file.metadata
    assert fetched.variants == file.variants
    assert fetched.inserted_at == file.inserted_at

    assert {:ok, deleted} =
             file |> StorageFile.status_changeset(%{status: "deleted"}) |> Catalog.update()

    assert {:ok, %{status: "deleted", id: id}} = Catalog.fetch(file.id)
    assert id == deleted.id
  end

  describe "changeset/2" do
    test "valid changeset with required fields" do
      attrs = %{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/2026/03/uuid.jpg",
        content_type: "image/jpeg",
        size: 1024
      }

      changeset = StorageFile.changeset(%StorageFile{}, attrs)
      assert changeset.valid?
    end

    test "invalid without required fields" do
      changeset = StorageFile.changeset(%StorageFile{}, %{})
      refute changeset.valid?

      errors = Keyword.keys(changeset.errors)
      assert :tenant in errors
      assert :type in errors
      assert :filename in errors
      assert :s3_key in errors
      assert :content_type in errors
      assert :size in errors
    end

    test "validates status inclusion" do
      attrs = %{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/2026/03/uuid.jpg",
        content_type: "image/jpeg",
        size: 1024,
        status: "invalid_status"
      }

      changeset = StorageFile.changeset(%StorageFile{}, attrs)
      refute changeset.valid?
      assert {:status, _} = List.keyfind(changeset.errors, :status, 0)
    end

    test "validates size is non-negative" do
      attrs = %{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/2026/03/uuid.jpg",
        content_type: "image/jpeg",
        size: -1
      }

      changeset = StorageFile.changeset(%StorageFile{}, attrs)
      refute changeset.valid?
      assert {:size, _} = List.keyfind(changeset.errors, :size, 0)

      assert StorageFile.changeset(%StorageFile{}, %{attrs | size: 0}).valid?
    end

    test "defaults status to active" do
      attrs = %{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/2026/03/uuid.jpg",
        content_type: "image/jpeg",
        size: 1024
      }

      changeset = StorageFile.changeset(%StorageFile{}, attrs)
      assert Ecto.Changeset.get_field(changeset, :status) == "active"
    end
  end

  describe "status_changeset/2" do
    test "updates status" do
      file = %StorageFile{status: "active"}
      changeset = StorageFile.status_changeset(file, %{status: "deleted"})
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == "deleted"
    end

    test "rejects invalid status" do
      file = %StorageFile{status: "active"}
      changeset = StorageFile.status_changeset(file, %{status: "bogus"})
      refute changeset.valid?
    end
  end
end
