defmodule GSMLG.Storage.StorageFileTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.StorageFile

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

    test "validates size is positive" do
      attrs = %{
        tenant: "default",
        type: "attachment",
        filename: "test.jpg",
        s3_key: "default/attachment/2026/03/uuid.jpg",
        content_type: "image/jpeg",
        size: 0
      }

      changeset = StorageFile.changeset(%StorageFile{}, attrs)
      refute changeset.valid?
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
