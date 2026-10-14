defmodule GSMLG.Storage.S3Client do
  @moduledoc """
  S3 client for storage operations.

  Creates its own AWS client that respects the storage-specific S3 endpoint
  configuration, enabling use with Minio and other S3-compatible services.
  """

  require Logger

  @doc "Captures one immutable S3 connection for an entire inventory operation."
  def capture_backend(config \\ Application.get_all_env(:gsmlg_storage)) do
    config = backend_config(config)

    with {:ok, access, secret} <- backend_credentials(config),
         client <-
           access
           |> AWS.Client.create(secret, config.region)
           |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, [decode_json: false]}),
         {:ok, client} <- configure_endpoint(client, config.endpoint) do
      {:ok, %{bucket: config.bucket, client: client, id: fingerprint(config)}}
    end
  end

  @doc "A backend identity that remains available even when configuration is invalid."
  def current_backend_id(config \\ Application.get_all_env(:gsmlg_storage)),
    do: config |> backend_config() |> fingerprint()

  @doc "Lists every object, preserving exact keys and failing the whole scan on page errors."
  def list_objects(%{client: client, bucket: bucket}) do
    list_pages(client, bucket, nil, MapSet.new(), [])
  end

  @doc "Reads object details from the captured backend."
  def head_object(%{client: client, bucket: bucket}, key) do
    with {:ok, _decoded, response} <- AWS.S3.head_object(client, bucket, key, %{}),
         headers <-
           Map.new(response.headers, fn {name, value} -> {String.downcase(name), value} end),
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

  defp list_pages(client, bucket, token, seen, pages) do
    with {:ok, decoded, _response} <- list_page(client, bucket, token),
         {:ok, objects, next} <- decode_page(decoded) do
      case next do
        nil ->
          {:ok, [objects | pages] |> Enum.reverse() |> List.flatten()}

        next ->
          if MapSet.member?(seen, next) do
            {:error, :repeated_s3_continuation_token}
          else
            list_pages(client, bucket, next, MapSet.put(seen, next), [objects | pages])
          end
      end
    end
  end

  defp list_page(client, bucket, token) do
    # URL encoding keeps whitespace and XML-invalid characters in keys intact.
    AWS.S3.list_objects_v2(client, bucket, token, nil, "url")
  rescue
    _error -> {:error, :invalid_s3_list_response}
  catch
    :exit, _reason -> {:error, :invalid_s3_list_response}
  end

  defp decode_page(%{"ListBucketResult" => result}) when is_map(result) do
    with "url" <- xml_text(result["EncodingType"]),
         truncated when truncated in ["true", "false"] <- xml_text(result["IsTruncated"]),
         {:ok, objects} <- decode_objects(result["Contents"]),
         {:ok, next} <- next_token(truncated, result["NextContinuationToken"]) do
      {:ok, objects, next}
    else
      _ -> {:error, :invalid_s3_list_response}
    end
  end

  defp decode_page(_decoded), do: {:error, :invalid_s3_list_response}

  defp decode_objects(nil), do: {:ok, []}
  defp decode_objects(object) when is_map(object), do: decode_objects([object])

  defp decode_objects(objects) when is_list(objects) do
    Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, acc} ->
      with key when is_binary(key) and key != "" <- xml_text(object["Key"]),
           false <- Regex.match?(~r/%(?![0-9a-fA-F]{2})/, key),
           {:ok, size} <- object["Size"] |> xml_text() |> nonnegative_integer(),
           modified when is_binary(modified) <- xml_text(object["LastModified"]),
           {:ok, _, _} <- DateTime.from_iso8601(modified),
           key <- URI.decode(key),
           true <- String.valid?(key) do
        entry = %{
          key: key,
          size: size,
          last_modified: modified,
          etag: xml_text(object["ETag"]),
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
  rescue
    _error -> {:error, :invalid_s3_list_response}
  end

  defp decode_objects(_objects), do: {:error, :invalid_s3_list_response}

  defp next_token("false", _token), do: {:ok, nil}

  defp next_token("true", token) do
    case xml_text(token) do
      token when is_binary(token) and token != "" -> {:ok, token}
      _ -> {:error, :invalid_s3_list_response}
    end
  end

  defp xml_text(value) when is_binary(value), do: value
  defp xml_text(%{"__text" => value}), do: value
  defp xml_text(_value), do: nil

  defp nonnegative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {size, ""} when size >= 0 -> {:ok, size}
      _ -> {:error, :invalid_s3_object_size}
    end
  end

  defp nonnegative_integer(_value), do: {:error, :invalid_s3_object_size}

  @doc "Creates a directory marker without overwriting an existing object's bytes."
  def put_folder_marker(%{client: client, bucket: bucket} = backend, key) do
    input = %{"Body" => "", "ContentType" => "application/x-directory", "IfNoneMatch" => "*"}

    case AWS.S3.put_object(client, bucket, key, input) do
      {:ok, _, _} ->
        :ok

      {:error, {:unexpected_response, %{status_code: 412}}} ->
        case head_object(backend, key) do
          {:ok, %{size: 0}} -> :ok
          {:ok, _} -> {:error, :folder_key_conflict}
          {:error, _} = error -> error
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Uploads an object to S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(%{client: client, bucket: bucket}, key, data, content_type) do
    case AWS.S3.put_object(client, bucket, key, %{"Body" => data, "ContentType" => content_type}) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def put_object(bucket, key, data, content_type) do
    with {:ok, client} <- get_client() do
      case client
           |> AWS.S3.put_object(bucket, key, %{
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

  defp multipart_file(%{client: client, bucket: bucket}, key, path, content_type),
    do: multipart_file_with_client(client, bucket, key, path, content_type)

  defp multipart_file(bucket, key, path, content_type) do
    with {:ok, client} <- get_client(),
         do: multipart_file_with_client(client, bucket, key, path, content_type)
  end

  defp multipart_file_with_client(client, bucket, key, path, content_type) do
    with {:ok, %{"UploadId" => upload_id}, _response} <-
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
  def get_object(%{client: client, bucket: bucket}, key) do
    case AWS.S3.get_object(client, bucket, key) do
      {:ok, body, response} -> extract_body(body, response)
      {:error, _} = error -> error
    end
  end

  def get_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case client |> AWS.S3.get_object(bucket, key) do
        {:ok, body, response} -> extract_body(body, response)
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
  def get_object_range(%{client: client, bucket: bucket}, key, first, last),
    do: range_with_client(client, bucket, key, first, last)

  def get_object_range(bucket, key, first, last) do
    with {:ok, client} <- get_client(), do: range_with_client(client, bucket, key, first, last)
  end

  defp range_with_client(client, bucket, key, first, last) do
    case get_object_with_range(client, bucket, key, "bytes=#{first}-#{last}") do
      {:ok, body, response} ->
        extract_body(body, response)

      {:error, {:unexpected_response, %{status_code: 206, body: body}}} when is_binary(body) ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Deletes an object from S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def delete_object(%{client: client, bucket: bucket}, key) do
    case AWS.S3.delete_object(client, bucket, key, %{}, []) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

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

  # AWS omits the decoded Body for a successful zero-byte object response.
  defp extract_body(_decoded, %{body: ""}), do: {:ok, ""}
  defp extract_body(%{"Body" => body}, _response) when is_binary(body), do: {:ok, body}
  defp extract_body(body, _response) when is_binary(body), do: {:ok, body}
  defp extract_body(_body, _response), do: {:error, :invalid_s3_response_body}

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
           |> AWS.Client.put_http_client({GSMLG.AWS.HttpClient, [decode_json: false]}) do
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
