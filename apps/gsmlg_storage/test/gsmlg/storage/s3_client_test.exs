defmodule GSMLG.Storage.S3ClientTest do
  use ExUnit.Case, async: false

  alias GSMLG.Storage.S3Client

  setup do
    original_endpoint = Application.fetch_env(:gsmlg_storage, :s3_endpoint)
    {:ok, original_endpoint: original_endpoint}
  end

  test "puts, gets, and deletes an object against the configured S3 endpoint", %{
    original_endpoint: original_endpoint
  } do
    endpoint = System.fetch_env!("AWS_ENDPOINT_URL")
    Application.put_env(:gsmlg_storage, :s3_endpoint, endpoint)

    bucket = Application.get_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    key = "tests/s3-client/#{Ecto.UUID.generate()}.txt"
    data = "s3-client-put-#{Ecto.UUID.generate()}"

    on_exit(fn ->
      Application.put_env(:gsmlg_storage, :s3_endpoint, endpoint)

      try do
        S3Client.delete_object(bucket, key)
      after
        restore_endpoint(original_endpoint)
      end
    end)

    assert :ok = S3Client.put_object(bucket, key, data, "text/plain")
    assert {:ok, ^data} = S3Client.get_object(bucket, key)
    assert :ok = S3Client.delete_object(bucket, key)
    assert {:error, _reason} = S3Client.get_object(bucket, key)
  end

  test "returns a clear error for a malformed custom endpoint", %{
    original_endpoint: original_endpoint
  } do
    endpoint = "not-a-valid-s3-endpoint"
    Application.put_env(:gsmlg_storage, :s3_endpoint, endpoint)

    on_exit(fn -> restore_endpoint(original_endpoint) end)

    assert {:error, {:invalid_s3_endpoint, ^endpoint}} =
             S3Client.put_object("bucket", "key", "data", "text/plain")
  end

  defp restore_endpoint({:ok, endpoint}) do
    Application.put_env(:gsmlg_storage, :s3_endpoint, endpoint)
  end

  defp restore_endpoint(:error) do
    Application.delete_env(:gsmlg_storage, :s3_endpoint)
  end
end
