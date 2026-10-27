defmodule GSMLG.AWS.HttpClientTest do
  use ExUnit.Case, async: true

  alias GSMLG.AWS.HttpClient

  test "preserves JSON requests, signed headers, query parameters and error status" do
    url =
      endpoint(fn socket, owner ->
        request = request(socket)
        send(owner, {:request, request})
        respond(socket, 403, "application/json", ~s({"error":"denied"}))
      end)

    assert {:ok, %{status_code: 403, body: %{"error" => "denied"}}} =
             HttpClient.request(
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

    assert {:ok, %{body: ^bytes}} = HttpClient.request(:get, url, "", [], decode_json: false)
  end

  test "preserves a DELETE request body used by signed API calls" do
    url =
      endpoint(fn socket, owner ->
        send(owner, {:delete_request, request(socket)})
        respond(socket, 200, "application/json", ~s({"ok":true}))
      end)

    assert {:ok, %{status_code: 200}} =
             HttpClient.request(:delete, url, %{name: "Alice"}, [], [])

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
             HttpClient.request(:get, url, "", [{"authorization", "secret"}], decode_json: false)

    refute_receive :redirect_destination_contacted
  end

  test "accepts the exact body limit and rejects a chunk that would exceed it" do
    for {body, expected} <- [{"12345", {:ok, "12345"}}, {"123456", {:error, :response_limit}}] do
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
        HttpClient.request(:get, url, "", [],
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

    assert {:error, :response_limit} =
             HttpClient.request(:get, url, "", [],
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

    assert {:error, :timeout} =
             HttpClient.request(:get, url, "", [],
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

    assert {:error, _reason} = HttpClient.request(:get, url, "", [], decode_json: false)
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
