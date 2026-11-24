defmodule GSMLG.Storage.S3Client do
  @moduledoc """
  S3 client for storage operations.

  Captures an independent S3 connection with `ExStorageServiceSdk`, supporting
  ESS, MinIO and other S3-compatible endpoints. Service and transport failures are
  returned as `{:error, %ExStorageServiceSdk.Error{}}`; `http_status` carries the
  S3 status (404, 412, 416, ...).
  """

  require Logger

  alias ExStorageServiceSdk.Error

  @part_size 5_242_880

  @doc "Captures one immutable S3 connection for an entire inventory operation."
  def capture_backend(config \\ Application.get_all_env(:gsmlg_storage)) do
    config = backend_config(config)

    with {:ok, access, secret} <- backend_credentials(config),
         {:ok, endpoint} <- endpoint(config),
         {:ok, client} <-
           ExStorageServiceSdk.new(
             endpoint: endpoint,
             region: config.region,
             access_key_id: access,
             secret_access_key: secret
           ) do
      {:ok, %{bucket: config.bucket, client: client, id: fingerprint(config)}}
    end
  end

  @doc "A backend identity that remains available even when configuration is invalid."
  def current_backend_id(config \\ Application.get_all_env(:gsmlg_storage)),
    do: config |> backend_config() |> fingerprint()

  @doc "Lists every object, preserving exact keys and failing the whole scan on page errors."
  def list_objects(%{client: client, bucket: bucket}) do
    client
    |> ExStorageServiceSdk.pages("ListObjectsV2", %{"Bucket" => bucket})
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, page}, {:ok, pages} ->
        case decode_objects(page["Contents"] || []) do
          {:ok, objects} -> {:cont, {:ok, [objects | pages]}}
          error -> {:halt, error}
        end

      {:error, _} = error, _acc ->
        {:halt, error}
    end)
    |> case do
      {:ok, pages} -> {:ok, pages |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  @doc "Reads object details from the captured backend."
  def head_object(%{client: client, bucket: bucket}, key) do
    with {:ok, %{headers: headers}} <- ExStorageServiceSdk.head_object(client, bucket, key),
         headers <- Map.new(headers, fn {name, value} -> {String.downcase(name), value} end),
         {:ok, size} <- nonnegative_integer(headers["content-length"]) do
      {:ok,
       %{
         key: key,
         size: size,
         etag: headers["etag"],
         last_modified: headers["last-modified"],
         content_type: headers["content-type"] || "application/octet-stream",
         metadata:
           headers
           |> Enum.filter(fn {name, _} -> String.starts_with?(name, "x-amz-meta-") end)
           |> Map.new(fn {name, value} ->
             {String.replace_prefix(name, "x-amz-meta-", ""), value}
           end)
       }}
    end
  end

  defp backend_config(config) do
    config = Map.new(config)

    %{
      bucket: Map.get(config, :s3_bucket, "gsmlg-storage"),
      endpoint: Map.get(config, :s3_endpoint),
      region: Map.get(config, :s3_region, "us-east-1"),
      access: Map.get(config, :s3_access_key_id) || System.get_env("AWS_ACCESS_KEY_ID"),
      secret: Map.get(config, :s3_secret_access_key) || System.get_env("AWS_SECRET_ACCESS_KEY")
    }
  end

  defp backend_credentials(%{access: access}) when access in [nil, ""],
    do: {:error, :missing_s3_access_key_id}

  defp backend_credentials(%{secret: secret}) when secret in [nil, ""],
    do: {:error, :missing_s3_secret_access_key}

  defp backend_credentials(%{access: access, secret: secret}), do: {:ok, access, secret}

  defp fingerprint(config),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(config)) |> Base.url_encode64(padding: false)

  defp decode_objects(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, acc} ->
      with key when is_binary(key) and key != "" <- object["Key"],
           size when is_integer(size) and size >= 0 <- object["Size"],
           %DateTime{} = modified <- object["LastModified"] do
        entry = %{
          key: key,
          size: size,
          last_modified: DateTime.to_iso8601(modified),
          etag: object["ETag"],
          folder?: size == 0 and String.ends_with?(key, "/")
        }

        {:cont, {:ok, [entry | acc]}}
      else
        _ -> {:halt, {:error, :invalid_s3_list_response}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, :invalid_s3_object_size}
    end
  end

  defp nonnegative_integer(_value), do: {:error, :invalid_s3_object_size}

  @doc "Creates a directory marker without overwriting an existing object's bytes."
  def put_folder_marker(%{client: client, bucket: bucket} = backend, key) do
    input = %{"ContentType" => "application/x-directory", "IfNoneMatch" => "*"}

    case ExStorageServiceSdk.put_object(client, bucket, key, "", input) do
      {:ok, _} ->
        :ok

      {:error, %Error{http_status: 412}} ->
        case head_object(backend, key) do
          {:ok, %{size: 0}} -> :ok
          {:ok, _} -> {:error, :folder_key_conflict}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc "Copies exact bytes and metadata without replacing a destination or changed source."
  def copy_object(%{client: client, bucket: bucket}, source, destination, etag)
      when is_binary(etag) and etag != "" do
    input = %{
      "CopySource" => %{"Bucket" => bucket, "Key" => source},
      "CopySourceIfMatch" => etag,
      "MetadataDirective" => "COPY",
      "TaggingDirective" => "COPY"
    }

    # The pinned S3 model has no CopyObject IfNoneMatch member; send it as a
    # signed request header on this call's config only.
    client = %{
      client
      | options:
          Map.update(
            client.options,
            :request_headers,
            [{"if-none-match", "*"}],
            &[{"if-none-match", "*"} | &1]
          )
    }

    case ExStorageServiceSdk.copy_object(client, bucket, destination, input) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def copy_object(_backend, _source, _destination, _etag),
    do: {:error, :missing_object_etag}

  @doc "Deletes only the object version observed by the folder operation."
  def delete_object(%{client: client, bucket: bucket}, key, etag)
      when is_binary(etag) and etag != "" do
    case ExStorageServiceSdk.delete_object(client, bucket, key, %{"IfMatch" => etag}) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def delete_object(_backend, _key, _etag), do: {:error, :missing_object_etag}

  @doc """
  Uploads an object to S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(%{client: client, bucket: bucket}, key, data, content_type) do
    case ExStorageServiceSdk.put_object(client, bucket, key, data, %{
           "ContentType" => content_type
         }) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def put_object(bucket, key, data, content_type) do
    with {:ok, client} <- get_client(),
         do: put_object(%{client: client, bucket: bucket}, key, data, content_type)
  end

  @doc "Uploads a file using bounded 5 MiB chunks."
  def put_file(bucket, key, path, content_type) do
    with {:ok, %{size: size}} <- File.stat(path) do
      if size <= @part_size do
        with {:ok, data} <- File.read(path), do: put_object(bucket, key, data, content_type)
      else
        multipart_file(bucket, key, path, content_type)
      end
    end
  end

  defp multipart_file(%{client: client, bucket: bucket}, key, path, content_type),
    do: multipart_file_with_client(client, bucket, key, path, content_type)

  defp multipart_file(bucket, key, path, content_type) do
    with {:ok, client} <- get_client(),
         do: multipart_file_with_client(client, bucket, key, path, content_type)
  end

  defp multipart_file_with_client(client, bucket, key, path, content_type) do
    with {:ok, result} <-
           ExStorageServiceSdk.create_multipart_upload(client, bucket, key, %{
             "ContentType" => content_type
           }),
         {:ok, upload_id} <- multipart_upload_id(result) do
      result =
        with {:ok, parts} <- upload_parts(client, bucket, key, upload_id, path),
             {:ok, _} <-
               ExStorageServiceSdk.complete_multipart_upload(
                 client,
                 bucket,
                 key,
                 upload_id,
                 parts
               ) do
          :ok
        end

      case result do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = ExStorageServiceSdk.abort_multipart_upload(client, bucket, key, upload_id)
          error
      end
    end
  end

  defp multipart_upload_id(%{"UploadId" => upload_id})
       when is_binary(upload_id) and upload_id != "",
       do: {:ok, upload_id}

  defp multipart_upload_id(_result), do: {:error, :invalid_s3_multipart_upload_id}

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
    case IO.binread(io, @part_size) do
      :eof ->
        {:ok, Enum.reverse(parts)}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        with {:ok, %{etag: etag}} <-
               ExStorageServiceSdk.upload_part(client, bucket, key, upload_id, number, chunk),
             {:ok, etag} <- multipart_part_etag(etag) do
          upload_part_chunks(client, bucket, key, upload_id, io, number + 1, [
            {number, etag} | parts
          ])
        end
    end
  end

  defp multipart_part_etag(etag) when is_binary(etag) and etag != "", do: {:ok, etag}
  defp multipart_part_etag(_etag), do: {:error, :invalid_s3_multipart_etag}

  @doc """
  Gets an object from S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def get_object(%{client: client, bucket: bucket}, key) do
    # TODO(upstream): gsmlg-dev/concord#98
    # ESS metadata reads can stall while validating a retained VSR log.
    read_object(client, bucket, key, %{})
  end

  def get_object(bucket, key) do
    with {:ok, client} <- get_client(), do: read_object(client, bucket, key, %{})
  end

  @doc """
  Gets an inclusive byte range from an object in S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  @spec get_object_range(map() | String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, binary()} | {:error, term()}
  def get_object_range(%{client: client, bucket: bucket}, key, first, last),
    do: read_object(client, bucket, key, %{"Range" => "bytes=#{first}-#{last}"})

  def get_object_range(bucket, key, first, last) do
    with {:ok, client} <- get_client(),
         do: read_object(client, bucket, key, %{"Range" => "bytes=#{first}-#{last}"})
  end

  # Upload limits do not bound existing objects or internal catalog metadata.
  # Consume the SDK stream to preserve full reads above its 8 MiB buffer default.
  defp read_object(client, bucket, key, input) do
    with {:ok, response} <- ExStorageServiceSdk.get_object_stream(client, bucket, key, input) do
      case ExStorageServiceSdk.S3.Decoder.decode_headers("GetObject", response) do
        {:ok, _metadata} ->
          with {:ok, chunks, _metadata} <-
                 client.transport.consume(response, [], &{:ok, [&1 | &2]}, []) do
            {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
          end

        {:error, _} = error ->
          client.transport.close(response)
          error
      end
    end
  end

  @doc """
  Deletes an object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(%{client: client, bucket: bucket}, key) do
    case ExStorageServiceSdk.delete_object(client, bucket, key) do
      {:ok, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def delete_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case ExStorageServiceSdk.delete_object(client, bucket, key) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete S3 object #{bucket}/#{key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_client do
    with {:ok, backend} <- capture_backend(), do: {:ok, backend.client}
  end

  defp endpoint(%{endpoint: endpoint, region: region}) when endpoint in [nil, ""],
    do: {:ok, "https://s3.#{region}.amazonaws.com"}

  defp endpoint(%{endpoint: endpoint_url}) do
    with {:ok, uri} <- parse_endpoint(endpoint_url),
         do: {:ok, URI.to_string(%{uri | path: nil})}
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
