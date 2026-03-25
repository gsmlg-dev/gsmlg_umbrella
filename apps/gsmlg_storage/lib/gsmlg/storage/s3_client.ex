defmodule GSMLG.Storage.S3Client do
  @moduledoc """
  S3 client for storage operations.

  Creates its own AWS client that respects the storage-specific S3 endpoint
  configuration, enabling use with Minio and other S3-compatible services.
  """

  require Logger

  @doc """
  Uploads an object to S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(bucket, key, data, content_type) do
    case get_client()
         |> AWS.S3.put_object(bucket, key, data, [{"Content-Type", content_type}]) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

  @doc """
  Gets an object from S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def get_object(bucket, key) do
    case get_client() |> AWS.S3.get_object(bucket, key) do
      {:ok, body, _resp} -> {:ok, body}
      {:error, _} = error -> error
    end
  end

  @doc """
  Deletes an object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(bucket, key) do
    case get_client() |> AWS.S3.delete_object(bucket, key, %{}, []) do
      {:ok, _, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to delete S3 object #{bucket}/#{key}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Build an AWS client for storage operations.
  # When a custom S3 endpoint is configured (e.g. Minio), creates a client
  # pointing at that endpoint. Otherwise falls back to the shared AWS client.
  defp get_client do
    endpoint = Application.get_env(:gsmlg_storage, :s3_endpoint)
    region = Application.get_env(:gsmlg_storage, :s3_region, "us-east-1")

    if endpoint not in [nil, ""] do
      build_custom_client(endpoint, region)
    else
      GSMLG.AWS.Client.get_client()
    end
  end

  defp build_custom_client(endpoint_url, region) do
    # For S3-compatible services, read credentials from env vars or storage config
    access_key_id =
      System.get_env("AWS_ACCESS_KEY_ID") ||
        Application.get_env(:gsmlg_storage, :s3_access_key_id, "minioadmin")

    secret_access_key =
      System.get_env("AWS_SECRET_ACCESS_KEY") ||
        Application.get_env(:gsmlg_storage, :s3_secret_access_key, "minioadmin")

    # Parse endpoint URL to extract host:port for AWS client
    uri = URI.parse(endpoint_url)
    proto = if uri.scheme == "https", do: "https://", else: "http://"
    host_port = "#{uri.host}:#{uri.port}"

    %AWS.Client{
      access_key_id: access_key_id,
      secret_access_key: secret_access_key,
      region: region,
      endpoint: {:keep_prefixes, host_port},
      proto: proto,
      port: uri.port
    }
    |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, []})
  end
end
