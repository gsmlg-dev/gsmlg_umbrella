defmodule GSMLG.StorageTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage

  describe "upload/4 input normalization" do
    test "rejects invalid input types" do
      assert {:error, :invalid_input} = Storage.upload(123, "tenant", "attachment")
      assert {:error, :invalid_input} = Storage.upload(nil, "tenant", "attachment")
    end

    test "rejects content type not in allowlist" do
      # Set up restricted allowed types for this test
      original = Application.get_env(:gsmlg_storage, :allowed_types)
      Application.put_env(:gsmlg_storage, :allowed_types, %{"restricted" => ~w(image/png)})

      result = Storage.upload({"test.txt", "hello world content"}, "tenant", "restricted")

      assert {:error, {:content_type_not_allowed, "application/octet-stream", "restricted"}} =
               result

      # Restore
      if original,
        do: Application.put_env(:gsmlg_storage, :allowed_types, original),
        else: Application.delete_env(:gsmlg_storage, :allowed_types)
    end
  end

  describe "stream_variant/2" do
    test "returns error for missing variant" do
      file = %GSMLG.Storage.StorageFile{variants: %{}}
      assert {:error, :variant_not_found} = Storage.stream_variant(file, "thumb")
    end

    test "returns error for nil variants" do
      file = %GSMLG.Storage.StorageFile{variants: nil}
      assert {:error, :variant_not_found} = Storage.stream_variant(file, "thumb")
    end
  end

  describe "purge/1" do
    test "rejects non-deleted files" do
      file = %GSMLG.Storage.StorageFile{status: "active"}
      assert {:error, :not_deleted} = Storage.purge(file)
    end
  end
end
