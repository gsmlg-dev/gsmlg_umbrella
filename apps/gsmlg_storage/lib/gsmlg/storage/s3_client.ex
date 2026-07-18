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
    with {:ok, client} <- get_client() do
      case client
           |> AWS.S3.put_object(key, bucket, %{
             "Body" => data,
             "ContentType" => content_type
           }) do
        {:ok, _, _} -> :ok
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Gets an object from S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def get_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case client |> AWS.S3.get_object(bucket, key) do
        {:ok, body, _resp} -> {:ok, body}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Gets an inclusive byte range from an object in S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  @spec get_object_range(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get_object_range(bucket, key, first, last) do
    range = "bytes=#{first}-#{last}"

    with {:ok, client} <- get_client() do
      case get_object_with_range(client, bucket, key, range) do
        {:ok, body, _resp} -> {:ok, body}
        {:error, _} = error -> error
      end
    end
  end

  @doc """
  Deletes an object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case client |> AWS.S3.delete_object(bucket, key, %{}, []) do
        {:ok, _, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete S3 object #{bucket}/#{key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_object_with_range(client, bucket, key, range) do
    arguments = [client, bucket, key] ++ List.duplicate(nil, 14) ++ [range]
    apply(AWS.S3, :get_object, arguments)
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
      {:ok, GSMLG.AWS.Client.get_client()}
    end
  end

  defp build_custom_client(endpoint_url, region) do
    with {:ok, uri} <- parse_endpoint(endpoint_url) do
      access_key_id =
        System.get_env("AWS_ACCESS_KEY_ID") ||
          Application.get_env(:gsmlg_storage, :s3_access_key_id)

      secret_access_key =
        System.get_env("AWS_SECRET_ACCESS_KEY") ||
          Application.get_env(:gsmlg_storage, :s3_secret_access_key)

      if is_nil(access_key_id) or is_nil(secret_access_key) do
        Logger.error(
          "S3 custom endpoint configured (#{endpoint_url}) but credentials are missing. " <>
            "Set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY env vars or configure via admin UI."
        )
      end

      client =
        %AWS.Client{
          access_key_id: access_key_id,
          secret_access_key: secret_access_key,
          region: region,
          endpoint: uri.host,
          proto: uri.scheme,
          port: uri.port
        }
        |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, []})

      {:ok, client}
    end
  end

  defp parse_endpoint(endpoint_url) when is_binary(endpoint_url) do
    case URI.parse(endpoint_url) do
      %URI{
        scheme: scheme,
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      } = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) and path in [nil, "", "/"] ->
        {:ok, uri}

      _uri ->
        {:error, {:invalid_s3_endpoint, endpoint_url}}
    end
  rescue
    URI.Error -> {:error, {:invalid_s3_endpoint, endpoint_url}}
  end

  defp parse_endpoint(endpoint_url), do: {:error, {:invalid_s3_endpoint, endpoint_url}}
end
