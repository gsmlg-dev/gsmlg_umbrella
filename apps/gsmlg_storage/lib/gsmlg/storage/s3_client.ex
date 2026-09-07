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

  @doc "Uploads a file using bounded 5 MiB chunks."
  def put_file(bucket, key, path, content_type) do
    with {:ok, %{size: size}} <- File.stat(path) do
      if size <= 5_242_880 do
        with {:ok, data} <- File.read(path), do: put_object(bucket, key, data, content_type)
      else
        multipart_file(bucket, key, path, content_type)
      end
    end
  end

  defp multipart_file(bucket, key, path, content_type) do
    with {:ok, client} <- get_client(),
         {:ok, %{"UploadId" => upload_id}, _response} <-
           AWS.S3.create_multipart_upload(client, bucket, key, %{"ContentType" => content_type}),
         {:ok, parts} <- upload_parts(client, bucket, key, upload_id, path) do
      case AWS.S3.complete_multipart_upload(client, bucket, key, %{
             "UploadId" => upload_id,
             "MultipartUpload" => %{"Parts" => parts}
           }) do
        {:ok, _result, _response} ->
          :ok

        {:error, _reason} = error ->
          _ = AWS.S3.abort_multipart_upload(client, bucket, key, %{"UploadId" => upload_id})
          error
      end
    end
  end

  defp upload_parts(client, bucket, key, upload_id, path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        upload_part_chunks(client, bucket, key, upload_id, io, 1, [])
      after
        File.close(io)
      end
    end
  end

  defp upload_part_chunks(client, bucket, key, upload_id, io, number, parts) do
    case IO.binread(io, 5_242_880) do
      :eof ->
        {:ok, Enum.reverse(parts)}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        case AWS.S3.upload_part(client, bucket, key, %{
               "UploadId" => upload_id,
               "PartNumber" => number,
               "Body" => chunk,
               "ContentLength" => byte_size(chunk)
             }) do
          {:ok, %{"ETag" => etag}, _response} ->
            upload_part_chunks(client, bucket, key, upload_id, io, number + 1, [
              %{"ETag" => etag, "PartNumber" => number} | parts
            ])

          {:error, _reason} = error ->
            _ = AWS.S3.abort_multipart_upload(client, bucket, key, %{"UploadId" => upload_id})
            error
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
        {:ok, body, _resp} -> extract_body(body)
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
        {:ok, body, _resp} ->
          extract_body(body)

        {:error, {:unexpected_response, %{status_code: 206, body: body}}}
        when is_binary(body) ->
          {:ok, body}

        {:error, _} = error ->
          error
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

  defp extract_body(%{"Body" => body}) when is_binary(body), do: {:ok, body}
  defp extract_body(body) when is_binary(body), do: {:ok, body}
  defp extract_body(_body), do: {:error, :invalid_s3_response_body}

  # Build an AWS client for storage operations.
  # When a custom S3 endpoint is configured (e.g. Minio), creates a client
  # pointing at that endpoint. Otherwise falls back to the shared AWS client.
  defp get_client do
    endpoint = Application.get_env(:gsmlg_storage, :s3_endpoint)
    region = Application.get_env(:gsmlg_storage, :s3_region, "us-east-1")

    with {:ok, access_key_id, secret_access_key} <- credentials(),
         client <-
           access_key_id
           |> AWS.Client.create(secret_access_key, region)
           |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, []}) do
      configure_endpoint(client, endpoint)
    end
  end

  defp configure_endpoint(client, endpoint) when endpoint in [nil, ""], do: {:ok, client}

  defp configure_endpoint(client, endpoint_url) do
    with {:ok, uri} <- parse_endpoint(endpoint_url) do
      {:ok, %{client | endpoint: uri.host, proto: uri.scheme, port: uri.port}}
    end
  end

  defp credentials do
    access_key_id =
      Application.get_env(:gsmlg_storage, :s3_access_key_id) ||
        System.get_env("AWS_ACCESS_KEY_ID")

    secret_access_key =
      Application.get_env(:gsmlg_storage, :s3_secret_access_key) ||
        System.get_env("AWS_SECRET_ACCESS_KEY")

    case {access_key_id, secret_access_key} do
      {value, _secret} when value in [nil, ""] -> {:error, :missing_s3_access_key_id}
      {_access, value} when value in [nil, ""] -> {:error, :missing_s3_secret_access_key}
      {access, secret} -> {:ok, access, secret}
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
