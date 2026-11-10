defmodule GSMLG.Storage.S3Request do
  @moduledoc false

  import SweetXml, only: [sigil_x: 2]

  # WORKAROUND(upstream): gsmlg-opt/ex_storage_service#25
  # Remove this bridge when the published standalone ESS SDK passes the storage
  # and attachment compatibility checks, including exact object keys.
  # Keep this bridge local to storage. ExAws supplies operation bodies, headers
  # and query parameters; aws_signature signs the final, once-encoded S3 URL.
  # ExAws.Operation.perform/2 normalizes dot segments and misreads '?' in keys.
  def request(client, %ExAws.Operation.S3{} = operation, response_kind) do
    body = IO.iodata_to_binary(operation.body)
    url = request_url(client, operation, response_kind)

    headers =
      operation.headers
      |> Map.new(fn {name, value} -> {String.downcase(to_string(name)), to_string(value)} end)
      |> Map.put("host", URI.parse(url).authority)
      |> Map.put("content-length", Integer.to_string(byte_size(body)))
      |> Map.to_list()

    headers =
      :aws_signature.sign_v4(
        client.access_key_id,
        client.secret_access_key,
        client.region,
        "s3",
        :calendar.universal_time(),
        operation.http_method |> Atom.to_string() |> String.upcase(),
        url,
        headers,
        body,
        uri_encode_path: false
      )

    case client.http_client.request(
           operation.http_method,
           url,
           body,
           headers,
           Map.get(client, :http_opts, [])
         ) do
      {:ok, %{status_code: status} = response} when status in 200..299 ->
        decode_response(response, response_kind)

      {:ok, response} ->
        {:error, {:unexpected_response, response}}

      {:error, %{reason: reason}} ->
        {:error, reason}
    end
  end

  def object_path(bucket, key), do: "/" <> encode_segment(bucket) <> "/" <> encode_key(key)

  # ExAws's completion builder accepts already formatted ETag XML text.
  def escape_xml(value) do
    String.replace(value, ["&", "<", ">", "\"", "'", "\r", "\n"], fn
      "&" -> "&amp;"
      "<" -> "&lt;"
      ">" -> "&gt;"
      "\"" -> "&quot;"
      "'" -> "&apos;"
      "\r" -> "&#13;"
      "\n" -> "&#10;"
    end)
  end

  defp request_url(client, operation, kind) do
    path =
      if kind == :list,
        do: "/" <> encode_segment(operation.bucket),
        else: object_path(operation.bucket, operation.path)

    uri = %URI{
      scheme: String.trim_trailing(client.scheme, "://"),
      host: client.host,
      port: client.port,
      path: path,
      query: query(operation)
    }

    URI.to_string(uri)
  end

  defp query(operation) do
    params = Map.new(operation.params)

    params =
      if operation.resource == "", do: params, else: Map.put(params, operation.resource, "")

    case params |> Enum.sort() |> URI.encode_query(:rfc3986) do
      "" -> nil
      value -> value
    end
  end

  defp encode_segment(value), do: URI.encode(value, &URI.char_unreserved?/1)
  defp encode_key(value), do: value |> String.split("/") |> Enum.map_join("/", &encode_segment/1)

  # Object bytes and successful empty responses never pass through XML or JSON.
  defp decode_response(response, :raw), do: {:ok, response.body, response}
  defp decode_response(response, :empty), do: {:ok, %{}, response}

  defp decode_response(response, kind) do
    case parse_xml(response.body, kind) do
      {:ok, decoded} -> {:ok, decoded, response}
      :service_error -> {:error, {:unexpected_response, response}}
      :error -> invalid_response(kind, response.body)
    end
  end

  defp invalid_response(:list, _body), do: {:error, :invalid_s3_list_response}
  defp invalid_response(:multipart_init, _body), do: {:error, :invalid_s3_multipart_upload_id}
  defp invalid_response(:copy, body), do: {:error, {:invalid_s3_copy_response, body}}

  defp invalid_response(:multipart_complete, _body),
    do: {:error, :invalid_s3_multipart_completion_response}

  defp parse_xml(body, kind) when is_binary(body) do
    document = SweetXml.parse(body, dtd: :none, quiet: true)
    :ok = ensure_complete_xml!(body)
    root = SweetXml.xpath(document, ~x"local-name(.)"s)

    case {root, kind} do
      {"Error", _} ->
        :service_error

      {"ListBucketResult", :list} ->
        result = fields(document, ~w(EncodingType IsTruncated NextContinuationToken))

        contents =
          document
          |> SweetXml.xpath(~x"./*[local-name()='Contents']"l)
          |> Enum.map(&fields(&1, ~w(Key Size LastModified ETag)))

        {:ok, %{root => Map.put(result, "Contents", contents)}}

      {"InitiateMultipartUploadResult", :multipart_init} ->
        {:ok, %{root => fields(document, ["UploadId"])}}

      {"CopyObjectResult", :copy} ->
        confirmed_result(document, root)

      {"CompleteMultipartUploadResult", :multipart_complete} ->
        confirmed_result(document, root)

      _ ->
        :error
    end
  rescue
    _error -> :error
  catch
    :exit, _reason -> :error
  end

  defp parse_xml(_body, _kind), do: :error

  # SweetXml returns the first document and discards any remainder. Validate EOF
  # with the public scanner as well, retaining entity and external-fetch denial.
  defp ensure_complete_xml!(body) do
    read_rules = fn _context, _name, _state -> :undefined end

    write_rules = fn
      :entity, _name, _value, _state -> raise ArgumentError, "XML entities are not permitted"
      _context, _name, _value, state -> state
    end

    options = [
      {:quiet, true},
      {:fetch_fun,
       fn _uri, _state -> raise ArgumentError, "External XML resources are not permitted" end},
      {:rules, read_rules, write_rules, nil}
    ]

    {_document, []} = :xmerl_scan.string(:binary.bin_to_list(body), options)
    :ok
  end

  defp confirmed_result(document, root) do
    case fields(document, ["ETag"]) do
      %{"ETag" => etag} = result when is_binary(etag) and etag != "" -> {:ok, %{root => result}}
      _ -> :error
    end
  end

  # Only decode the fields consumed by storage. Missing values stay nil and
  # duplicate scalar elements stay lists, so strict validators reject ambiguity.
  defp fields(node, names) do
    children = SweetXml.xpath(node, ~x"./*"l)

    Map.new(names, fn name ->
      values =
        children
        |> Enum.filter(&(SweetXml.xpath(&1, ~x"local-name(.)"s) == name))
        |> Enum.map(fn child ->
          if SweetXml.xpath(child, ~x"./*"l) == [],
            do: child |> SweetXml.xpath(~x"./text()"ls) |> Enum.join(),
            else: :invalid_xml_field
        end)

      value =
        case values do
          [] -> nil
          [value] -> value
          values -> values
        end

      {name, value}
    end)
  end
end
