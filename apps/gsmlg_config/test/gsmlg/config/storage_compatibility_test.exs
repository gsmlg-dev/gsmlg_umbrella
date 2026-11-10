defmodule GSMLG.Config.StorageCompatibilityTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.{Schema, Setup}

  @storage_keys [
    :s3_bucket,
    :s3_endpoint,
    :s3_region,
    :s3_access_key_id,
    :s3_secret_access_key,
    :max_file_size,
    :cleanup_interval,
    :retention_window
  ]

  setup do
    previous = Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)
  end

  test "S3-compatible storage configuration preserves independently supplied credentials" do
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "storage-access")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "storage-secret")

    assert {:ok, config} =
             Schema.validate_section(:storage, %{
               s3_bucket: "attachments",
               s3_endpoint: "https://objects.example.test:9443",
               s3_region: "storage-region"
             })

    Setup.setup_storage(config)

    assert Application.fetch_env!(:gsmlg_storage, :s3_bucket) == "attachments"

    assert Application.fetch_env!(:gsmlg_storage, :s3_endpoint) ==
             "https://objects.example.test:9443"

    assert Application.fetch_env!(:gsmlg_storage, :s3_region) == "storage-region"
    assert Application.fetch_env!(:gsmlg_storage, :s3_access_key_id) == "storage-access"
    assert Application.fetch_env!(:gsmlg_storage, :s3_secret_access_key) == "storage-secret"
  end
end
