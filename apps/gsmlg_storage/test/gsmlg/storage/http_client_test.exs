defmodule GSMLG.Storage.HTTPClientTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.{HTTPClient, S3Client}

  test "S3-compatible uploads retain the storage endpoint, signed headers and raw bytes" do
    bytes = <<0, 255, 1, 2>>

    url =
      endpoint(fn socket, owner ->
        send(owner, {:s3_request, request(socket)})
        respond(socket, 200, "application/xml", "")
      end)

    endpoint = url |> URI.parse() |> Map.put(:path, "") |> URI.to_string()

    assert {:ok, backend} =
             GSMLG.Storage.S3Client.capture_backend(
               s3_bucket: "attachments",
               s3_endpoint: endpoint,
               s3_region: "storage-region",
               s3_access_key_id: "storage-access",
               s3_secret_access_key: "storage-secret"
             )

    assert :ok =
             GSMLG.Storage.S3Client.put_object(
               backend,
               "raw.bin",
               bytes,
               "application/octet-stream"
             )

    assert_receive {:s3_request, request}

    ["PUT", target, "HTTP/1.1"] =
      request |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")

    assert URI.parse(target).path == "/attachments/raw.bin"
    [headers, ^bytes] = String.split(request, "\r\n\r\n", parts: 2)
    assert String.downcase(headers) =~ "authorization: aws4-hmac-sha256"
    assert request =~ "Credential=storage-access/"
    assert request =~ "/storage-region/s3/aws4_request"
    assert String.ends_with?(request, bytes)
    assert_wire_signature(request)
  end

  test "preserves JSON requests, signed headers, query parameters and error status" do
    url =
      endpoint(fn socket, owner ->
        request = request(socket)
        send(owner, {:request, request})
        respond(socket, 403, "application/json", ~s({"error":"denied"}))
      end)

    assert {:ok, %{status_code: 403, body: %{"error" => "denied"}}} =
             HTTPClient.request(
               :post,
               url <> "?key=a%2Bb",
               %{name: "Alice"},
               [{"authorization", "signed value"}],
               []
             )

    assert_receive {:request, request}
    assert request =~ "POST /resource?key=a%2Bb HTTP/1.1"
    assert String.downcase(request) =~ "authorization: signed value"
    assert request =~ ~s({"name":"Alice"})
  end

  test "preserves compressed wire bytes when JSON decoding is disabled" do
    bytes = :zlib.gzip("wire bytes")

    url =
      endpoint(fn socket, _owner ->
        request(socket)

        :gen_tcp.send(socket, [
          "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: ",
          Integer.to_string(byte_size(bytes)),
          "\r\nConnection: close\r\n\r\n",
          bytes
        ])
      end)

    assert {:ok, %{body: ^bytes}} = HTTPClient.request(:get, url, "", [], decode_json: false)
  end

  test "preserves a DELETE request body used by signed API calls" do
    url =
      endpoint(fn socket, owner ->
        send(owner, {:delete_request, request(socket)})
        respond(socket, 200, "application/json", ~s({"ok":true}))
      end)

    assert {:ok, %{status_code: 200}} =
             HTTPClient.request(:delete, url, %{name: "Alice"}, [], [])

    assert_receive {:delete_request, request}
    assert request =~ "DELETE /resource HTTP/1.1"
    assert request =~ ~s({"name":"Alice"})
  end

  test "returns redirects without forwarding authorization to their destination" do
    target =
      endpoint(fn socket, owner ->
        send(owner, :redirect_destination_contacted)
        request(socket)
        respond(socket, 200, "text/plain", "destination")
      end)

    url =
      endpoint(fn socket, _owner ->
        request(socket)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 302 Found\r\nLocation: #{target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
      end)

    assert {:ok, %{status_code: 302, body: ""}} =
             HTTPClient.request(:get, url, "", [{"authorization", "secret"}], decode_json: false)

    refute_receive :redirect_destination_contacted
  end

  test "accepts the exact body limit and rejects a chunk that would exceed it" do
    for {body, expected} <- [
          {"12345", {:ok, "12345"}},
          {"123456", {:error, %{reason: :response_limit}}}
        ] do
      url =
        endpoint(fn socket, _owner ->
          request(socket)

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
            Integer.to_string(byte_size(body), 16),
            "\r\n",
            body,
            "\r\n0\r\n\r\n"
          ])
        end)

      result =
        HTTPClient.request(:get, url, "", [],
          decode_json: false,
          adapter: [max_body_bytes: 5, receive_timeout: 1_000]
        )

      case expected do
        {:ok, body} -> assert {:ok, %{body: ^body}} = result
        error -> assert result == error
      end
    end
  end

  test "rejects an oversized Content-Length without waiting for its body and closes the connection" do
    url =
      endpoint(fn socket, owner ->
        request(socket)
        :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\n")
        send(owner, {:peer_closed, :gen_tcp.recv(socket, 0, 2_000)})
      end)

    assert {:error, %{reason: :response_limit}} =
             HTTPClient.request(:get, url, "", [],
               decode_json: false,
               adapter: [max_body_bytes: 5, receive_timeout: 500]
             )

    assert_receive {:peer_closed, {:error, :closed}}, 1_000
  end

  test "returns timeout and truncated-response failures without a partial success" do
    url =
      endpoint(fn socket, _owner ->
        request(socket)
        :gen_tcp.recv(socket, 0, 1_000)
      end)

    assert {:error, %{reason: :timeout}} =
             HTTPClient.request(:get, url, "", [],
               decode_json: false,
               adapter: [receive_timeout: 50]
             )

    url =
      endpoint(fn socket, _owner ->
        request(socket)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nab"
        )
      end)

    assert {:error, %{reason: _reason}} =
             HTTPClient.request(:get, url, "", [], decode_json: false)
  end

  for key <- [
        " 中文 +%.txt ",
        "literal?query=value.txt",
        "literal#fragment.txt",
        "/leading.txt",
        "repeated//slash.txt",
        "folder/./file.txt",
        "folder/../file.txt"
      ] do
    @key key
    test "S3 wire requests preserve the exact object key #{inspect(key)}" do
      url =
        endpoint(fn socket, owner ->
          send(owner, {:key_request, request(socket)})
          respond(socket, 200, "application/octet-stream", "bytes")
        end)

      assert {:ok, "bytes"} = S3Client.get_object(backend(url), @key)
      assert_receive {:key_request, request}
      ["GET", target, "HTTP/1.1"] = request_line(request)
      uri = URI.parse(target)
      assert URI.decode(uri.path) == "/attachments/" <> @key
      assert uri.fragment == nil
      assert_wire_signature(request)
    end
  end

  test "S3 listing signs the exact query parameters sent over the wire" do
    url =
      endpoint(fn socket, owner ->
        send(owner, {:list_request, request(socket)})

        respond(socket, 200, "application/xml", """
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
          <EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>
        </ListBucketResult>
        """)
      end)

    assert {:ok, []} = S3Client.list_objects(backend(url))
    assert_receive {:list_request, request}
    ["GET", target, "HTTP/1.1"] = request_line(request)
    query = target |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["list-type"] == "2"
    assert query["encoding-type"] == "url"
    assert_wire_signature(request)
  end

  test "S3 GET and range failures retain status codes required by callers" do
    for {status, code} <- [{404, "NoSuchKey"}, {416, "InvalidRange"}] do
      url =
        endpoint(fn socket, owner ->
          send(owner, {:failed_request, request(socket)})
          respond(socket, status, "application/xml", "<Error><Code>#{code}</Code></Error>")
        end)

      backend = backend(url)

      result =
        if status == 404,
          do: S3Client.get_object(backend, "missing"),
          else: S3Client.get_object_range(backend, "empty", 0, 0)

      assert {:error, {:unexpected_response, %{status_code: ^status}}} = result
      assert_receive {:failed_request, request}
      if status == 416, do: assert(request_headers(request)["range"] == "bytes=0-0")
    end
  end

  test "S3 GET preserves compressed, JSON, binary and empty response bytes" do
    for {bytes, content_type, encoding} <- [
          {:zlib.gzip("wire bytes"), "application/octet-stream", "gzip"},
          {" {\"unchanged\": true} \n", "application/json", nil},
          {<<0, 255, 1, 2>>, "application/octet-stream", nil},
          {"", "application/octet-stream", nil}
        ] do
      url =
        endpoint(fn socket, _owner ->
          request(socket)
          encoding_header = if encoding, do: "Content-Encoding: #{encoding}\r\n", else: ""

          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Type: #{content_type}\r\n",
            encoding_header,
            "Content-Length: #{byte_size(bytes)}\r\nConnection: close\r\n\r\n",
            bytes
          ])
        end)

      assert {:ok, ^bytes} = S3Client.get_object(backend(url), "object")
    end
  end

  test "S3 byte ranges are inclusive and return exact HTTP 206 bytes" do
    bytes = <<255, 0, 1>>

    url =
      endpoint(fn socket, owner ->
        send(owner, {:range_request, request(socket)})

        :gen_tcp.send(socket, [
          "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 2-4/8\r\n",
          "Content-Length: 3\r\nConnection: close\r\n\r\n",
          bytes
        ])
      end)

    assert {:ok, ^bytes} = S3Client.get_object_range(backend(url), "object", 2, 4)
    assert_receive {:range_request, request}
    assert request_headers(request)["range"] == "bytes=2-4"
    assert_wire_signature(request)
  end

  test "S3 folder markers, copies and deletes send their concurrency conditions" do
    url =
      endpoint(fn socket, owner ->
        send(owner, {:marker_request, request(socket)})
        respond(socket, 200, "application/xml", "")
      end)

    assert :ok = S3Client.put_folder_marker(backend(url), "empty/")
    assert_receive {:marker_request, request}
    assert request_headers(request)["if-none-match"] == "*"
    assert_wire_signature(request)

    source = "/目录//a/./../ +%?#.txt"
    etag = ~s("source-etag")

    url =
      endpoint(fn socket, owner ->
        send(owner, {:copy_request, request(socket)})

        respond(socket, 200, "application/xml", """
        <CopyObjectResult><ETag>&quot;copied&quot;</ETag>
        <LastModified>2026-10-14T01:00:00Z</LastModified></CopyObjectResult>
        """)
      end)

    assert :ok = S3Client.copy_object(backend(url), source, "destination.txt", etag)
    assert_receive {:copy_request, request}
    headers = request_headers(request)
    assert headers["if-none-match"] == "*"
    assert headers["x-amz-copy-source-if-match"] == etag
    assert headers["x-amz-metadata-directive"] == "COPY"
    assert headers["x-amz-tagging-directive"] == "COPY"

    assert URI.decode(String.trim_leading(headers["x-amz-copy-source"], "/")) ==
             "attachments/" <> source

    assert headers["x-amz-copy-source"] =~ "%3F"
    assert headers["x-amz-copy-source"] =~ "%23"
    assert headers["x-amz-copy-source"] =~ "%2B"
    assert headers["x-amz-copy-source"] =~ "%25"
    assert_wire_signature(request)

    url =
      endpoint(fn socket, owner ->
        send(owner, {:conditional_delete_request, request(socket)})
        respond(socket, 204, "application/xml", "")
      end)

    assert :ok = S3Client.delete_object(backend(url), "object", etag)
    assert_receive {:conditional_delete_request, request}
    assert request_headers(request)["if-match"] == etag
    assert_wire_signature(request)
  end

  test "signed S3 redirects fail without contacting their destination" do
    target =
      endpoint(fn socket, owner ->
        send(owner, :s3_redirect_destination_contacted)
        request(socket)
        respond(socket, 200, "application/octet-stream", "destination")
      end)

    url =
      endpoint(fn socket, owner ->
        send(owner, {:signed_redirect_request, request(socket)})

        :gen_tcp.send(socket, [
          "HTTP/1.1 302 Found\r\nLocation: #{target}\r\n",
          "Content-Length: 0\r\nConnection: close\r\n\r\n"
        ])
      end)

    assert {:error, {:unexpected_response, %{status_code: 302}}} =
             S3Client.get_object(backend(url), "object")

    assert_receive {:signed_redirect_request, request}
    assert request_headers(request)["authorization"] =~ "AWS4-HMAC-SHA256"
    refute_receive :s3_redirect_destination_contacted
  end

  defp backend(url) do
    endpoint = url |> URI.parse() |> Map.put(:path, "") |> URI.to_string()

    {:ok, backend} =
      S3Client.capture_backend(
        s3_bucket: "attachments",
        s3_endpoint: endpoint,
        s3_region: "storage-region",
        s3_access_key_id: "storage-access",
        s3_secret_access_key: "storage-secret"
      )

    backend
  end

  defp assert_wire_signature(request) do
    [method, target, "HTTP/1.1"] = request_line(request)
    headers = request_headers(request)
    [_, body] = String.split(request, "\r\n\r\n", parts: 2)
    authorization = Map.fetch!(headers, "authorization")
    [_, signed_names] = Regex.run(~r/SignedHeaders=([^, ]+)/, authorization)
    signed_names = String.split(signed_names, ";")
    assert "host" in signed_names
    assert "x-amz-date" in signed_names
    assert "x-amz-content-sha256" in signed_names

    for name <- Map.keys(headers),
        String.starts_with?(name, "x-amz-") or name in ["range", "if-match", "if-none-match"] do
      assert name in signed_names
    end

    assert headers["x-amz-content-sha256"] ==
             Base.encode16(:crypto.hash(:sha256, body), case: :lower)

    <<year::binary-size(4), month::binary-size(2), day::binary-size(2), "T", hour::binary-size(2),
      minute::binary-size(2), second::binary-size(2),
      "Z">> =
      Map.fetch!(headers, "x-amz-date")

    timestamp =
      {{String.to_integer(year), String.to_integer(month), String.to_integer(day)},
       {String.to_integer(hour), String.to_integer(minute), String.to_integer(second)}}

    unsigned_headers =
      headers
      |> Map.take(signed_names)
      |> Map.drop(["x-amz-date", "x-amz-content-sha256"])
      |> Map.to_list()

    expected_headers =
      :aws_signature.sign_v4(
        "storage-access",
        "storage-secret",
        "storage-region",
        "s3",
        timestamp,
        method,
        "http://" <> Map.fetch!(headers, "host") <> target,
        unsigned_headers,
        body,
        uri_encode_path: false
      )

    expected =
      Enum.find_value(expected_headers, fn {name, value} ->
        if String.downcase(name) == "authorization", do: value
      end)

    assert authorization == expected
  end

  defp request_line(request),
    do: request |> String.split("\r\n", parts: 2) |> hd() |> String.split(" ")

  defp request_headers(request) do
    [headers, _body] = String.split(request, "\r\n\r\n", parts: 2)

    headers
    |> String.split("\r\n")
    |> tl()
    |> Map.new(fn header ->
      [name, value] = String.split(header, ":", parts: 2)
      {String.downcase(name), String.trim(value)}
    end)
  end

  defp endpoint(handler) do
    owner = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)

    server =
      spawn_link(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            try do
              handler.(socket, owner)
            after
              :gen_tcp.close(socket)
            end

          {:error, :closed} ->
            :ok
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
    end)

    "http://127.0.0.1:#{port}/resource"
  end

  defp request(socket, bytes \\ "") do
    if String.contains?(bytes, "\r\n\r\n") do
      [headers, body] = String.split(bytes, "\r\n\r\n", parts: 2)
      length = Regex.run(~r/content-length: (\d+)/i, headers, capture: :all_but_first)
      length = if length, do: length |> hd() |> String.to_integer(), else: 0
      if byte_size(body) >= length, do: bytes, else: receive_more(socket, bytes)
    else
      receive_more(socket, bytes)
    end
  end

  defp receive_more(socket, bytes) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 2_000)
    request(socket, bytes <> chunk)
  end

  defp respond(socket, status, type, body) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 #{status} Response\r\nContent-Type: #{type}\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\nConnection: close\r\n\r\n",
      body
    ])
  end
end
