defmodule GSMLG.Storage.S3Client do
  @moduledoc """
  S3 client for storage operations.

  Captures an independent S3 connection using ExAws operation builders and the
  public AWS signer, with storage-specific endpoints for Minio and compatible services.
  """

  require Logger

  alias GSMLG.Storage.S3Request

  @doc "Captures one immutable S3 connection for an entire inventory operation."
  def capture_backend(config \\ Application.get_all_env(:gsmlg_storage)) do
    config = backend_config(config)

    with {:ok, access, secret} <- backend_credentials(config),
         client <-
           ExAws.Config.new(:s3,
             access_key_id: access,
             secret_access_key: secret,
             region: config.region,
             http_client: GSMLG.Storage.HTTPClient,
             http_opts: [decode_json: false],
             normalize_path: false,
             retries: [max_attempts: 1],
             refreshable: false
           ),
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
    with {:ok, _decoded, response} <- request(client, ExAws.S3.head_object(bucket, key), :empty),
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
    options = [encoding_type: "url"]
    options = if token, do: Keyword.put(options, :continuation_token, token), else: options
    request(client, ExAws.S3.list_objects_v2(bucket, options), :list)
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
    operation =
      ExAws.S3.put_object(bucket, key, "", content_type: "application/x-directory")
      |> put_headers(%{"if-none-match" => "*"})

    case request(client, operation, :empty) do
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

  @doc "Copies exact bytes and metadata without replacing a destination or changed source."
  def copy_object(%{client: client, bucket: bucket}, source, destination, etag)
      when is_binary(etag) and etag != "" do
    operation =
      ExAws.S3.put_object_copy(bucket, destination, bucket, source,
        copy_source_if_match: etag,
        metadata_directive: "COPY",
        tagging_directive: "COPY"
      )
      |> put_headers(%{
        "x-amz-copy-source" =>
          S3Request.object_path(bucket, source) |> String.replace_prefix("/", ""),
        "x-amz-copy-source-if-match" => etag,
        "if-none-match" => "*",
        "x-amz-metadata-directive" => "COPY",
        "x-amz-tagging-directive" => "COPY"
      })

    case request(client, operation, :copy) do
      {:ok, %{"CopyObjectResult" => result}, _} when is_map(result) -> :ok
      {:ok, result, _} -> {:error, {:invalid_s3_copy_response, result}}
      {:error, _} = error -> error
    end
  end

  def copy_object(_backend, _source, _destination, _etag),
    do: {:error, :missing_object_etag}

  @doc "Deletes only the object version observed by the folder operation."
  def delete_object(%{client: client, bucket: bucket}, key, etag)
      when is_binary(etag) and etag != "" do
    operation = ExAws.S3.delete_object(bucket, key) |> put_headers(%{"if-match" => etag})

    case request(client, operation, :empty) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def delete_object(_backend, _key, _etag), do: {:error, :missing_object_etag}

  @doc """
  Uploads an object to S3.
  Returns `:ok` or `{:error, reason}`.
  """
  def put_object(%{client: client, bucket: bucket}, key, data, content_type) do
    operation = ExAws.S3.put_object(bucket, key, data, content_type: content_type)

    case request(client, operation, :empty) do
      {:ok, _, _} -> :ok
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
    with {:ok, result, _response} <-
           request(
             client,
             ExAws.S3.initiate_multipart_upload(bucket, key, content_type: content_type),
             :multipart_init
           ),
         {:ok, upload_id} <- multipart_upload_id(result) do
      result =
        with {:ok, parts} <- upload_parts(client, bucket, key, upload_id, path),
             {:ok, %{"CompleteMultipartUploadResult" => %{}}, _response} <-
               request(
                 client,
                 ExAws.S3.complete_multipart_upload(bucket, key, upload_id, parts),
                 :multipart_complete
               ) do
          :ok
        else
          {:ok, _result, _response} -> {:error, :invalid_s3_multipart_completion_response}
          {:error, _reason} = error -> error
        end

      case result do
        :ok ->
          :ok

        {:error, _reason} = error ->
          _ = request(client, ExAws.S3.abort_multipart_upload(bucket, key, upload_id), :empty)
          error
      end
    end
  end

  defp multipart_upload_id(%{"InitiateMultipartUploadResult" => result}),
    do: multipart_upload_id(result)

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
    case IO.binread(io, 5_242_880) do
      :eof ->
        {:ok, Enum.reverse(parts)}

      {:error, reason} ->
        {:error, reason}

      chunk ->
        operation = ExAws.S3.upload_part(bucket, key, upload_id, number, chunk)

        case request(client, operation, :empty) do
          {:ok, result, response} ->
            with {:ok, etag} <- multipart_part_etag(result, response) do
              upload_part_chunks(client, bucket, key, upload_id, io, number + 1, [
                {number, S3Request.escape_xml(etag)} | parts
              ])
            end

          {:error, _reason} = error ->
            error
        end
    end
  end

  defp multipart_part_etag(%{"ETag" => etag}, _response)
       when is_binary(etag) and etag != "",
       do: {:ok, etag}

  defp multipart_part_etag(_result, %{headers: headers}) do
    case Enum.find(headers, fn {name, _value} -> String.downcase(name) == "etag" end) do
      {_name, etag} when is_binary(etag) and etag != "" -> {:ok, etag}
      _ -> {:error, :invalid_s3_multipart_etag}
    end
  end

  @doc """
  Gets an object from S3.
  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def get_object(%{client: client, bucket: bucket}, key) do
    # TODO(upstream): gsmlg-dev/concord#98
    # ESS metadata reads can stall while validating a retained VSR log.
    case request(client, ExAws.S3.get_object(bucket, key), :raw) do
      {:ok, body, response} -> extract_body(body, response)
      {:error, _} = error -> error
    end
  end

  def get_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case request(client, ExAws.S3.get_object(bucket, key), :raw) do
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
    case request(client, ExAws.S3.delete_object(bucket, key), :empty) do
      {:ok, _, _} -> :ok
      {:error, _} = error -> error
    end
  end

  def delete_object(bucket, key) do
    with {:ok, client} <- get_client() do
      case request(client, ExAws.S3.delete_object(bucket, key), :empty) do
        {:ok, _, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Failed to delete S3 object #{bucket}/#{key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  defp get_object_with_range(client, bucket, key, range) do
    request(client, ExAws.S3.get_object(bucket, key, range: range), :raw)
  end

  # Preserve raw object bytes, including successful zero-byte responses.
  defp extract_body(body, _response) when is_binary(body), do: {:ok, body}
  defp extract_body(_body, _response), do: {:error, :invalid_s3_response_body}

  defp request(client, operation, response_kind),
    do: S3Request.request(client, operation, response_kind)

  defp put_headers(operation, headers),
    do: %{operation | headers: Map.merge(operation.headers, headers)}

  defp get_client do
    with {:ok, backend} <- capture_backend(), do: {:ok, backend.client}
  end

  defp configure_endpoint(client, endpoint) when endpoint in [nil, ""], do: {:ok, client}

  defp configure_endpoint(client, endpoint_url) do
    with {:ok, uri} <- parse_endpoint(endpoint_url) do
      {:ok, %{client | host: uri.host, scheme: uri.scheme <> "://", port: uri.port}}
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
