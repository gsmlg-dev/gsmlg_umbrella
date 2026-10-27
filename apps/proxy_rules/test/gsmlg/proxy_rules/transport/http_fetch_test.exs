defmodule GSMLG.ProxyRules.Transport.HTTPFetchTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Transport
  alias GSMLG.ProxyRules.Transport.HTTPFetch, as: HTTPFetchTransport
  alias GSMLG.ProxyRules.Snapshot

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:http_fetch)
    :ok
  end

  test "streams a small chunked response and preserves binary headers" do
    {url, server} =
      start_server(fn socket, parent ->
        recv_request(socket)
        send(parent, :request_received)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            "Transfer-Encoding: chunked\r\n",
            "X-Mixed-Case: Value\r\n\r\n",
            "5\r\nhello\r\n",
            "6\r\n world\r\n",
            "0\r\n\r\n"
          ])
      end)

    assert {:ok, %{status: 200, headers: headers, body: "hello world"}} =
             HTTPFetchTransport.get(url, [{"accept", "text/plain"}],
               receive_timeout: 1_000,
               max_body_size: 32
             )

    assert_receive :request_received

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(name) == "x-mixed-case" and value == "Value"
           end)

    await_server(server)
  end

  test "halts an oversized chunked response before the server releases the remainder" do
    parent = self()

    {url, server} =
      start_server(fn socket, _parent ->
        recv_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\n123456\r\n"
          )

        send(parent, {:oversized_chunk_sent, self()})

        receive do
          :release_remainder ->
            :gen_tcp.send(socket, "6\r\nsecret\r\n0\r\n\r\n")
        end
      end)

    assert {:error, :body_too_large} =
             HTTPFetchTransport.get(url, [],
               receive_timeout: 1_000,
               max_body_size: 5
             )

    assert_receive {:oversized_chunk_sent, server_pid}
    assert Process.alive?(server_pid)
    send(server_pid, :release_remainder)
    await_server(server)
  end

  test "accepts the exact body limit and rejects limit plus one" do
    for {body, expected} <- [{"12345", {:ok, "12345"}}, {"123456", {:error, :body_too_large}}] do
      {url, server} =
        start_server(fn socket, _parent ->
          recv_request(socket)

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\n",
              "Transfer-Encoding: chunked\r\n",
              "Connection: close\r\n\r\n",
              Integer.to_string(byte_size(body), 16),
              "\r\n",
              body,
              "\r\n0\r\n\r\n"
            ])
        end)

      case expected do
        {:ok, expected_body} ->
          assert {:ok, %{body: ^expected_body}} =
                   HTTPFetchTransport.get(url, [], transport_options(5))

        {:error, reason} ->
          assert {:error, ^reason} =
                   HTTPFetchTransport.get(url, [], transport_options(5))
      end

      await_server(server)
    end
  end

  test "supports content-length bodies and empty 204 and 304 responses" do
    for {status, body} <- [{200, "content"}, {204, ""}, {304, ""}] do
      {url, server} =
        start_server(fn socket, _parent ->
          recv_request(socket)

          :gen_tcp.send(socket, [
            "HTTP/1.1 #{status} Status\r\n",
            "Content-Length: #{byte_size(body)}\r\n",
            "Connection: close\r\n\r\n",
            body
          ])
        end)

      assert {:ok, %{status: ^status, body: ^body}} =
               HTTPFetchTransport.get(url, [],
                 receive_timeout: 1_000,
                 max_body_size: 32
               )

      await_server(server)
    end
  end

  test "discards interim response headers and body accounting before the final response" do
    {url, server} =
      start_server(fn socket, _parent ->
        recv_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 103 Early Hints\r\n",
            "ETag: interim\r\n",
            "Content-Length: 99999\r\n\r\n",
            "HTTP/1.1 200 OK\r\n",
            "ETag: final\r\n",
            "Content-Length: 2\r\n",
            "Connection: close\r\n\r\n",
            "ok"
          ])
      end)

    assert {:ok, %{status: 200, headers: headers, body: "ok"}} =
             HTTPFetchTransport.get(url, [], transport_options(8))

    assert header_value(headers, "etag") == "final"
    refute Enum.any?(headers, fn {_name, value} -> value == "interim" end)
    await_server(server)
  end

  test "halts when aggregate response headers exceed the fixed limit" do
    large_headers =
      for index <- 1..70 do
        ["X-Large-", Integer.to_string(index), ": ", :binary.copy("x", 1_000), "\r\n"]
      end

    {url, server} =
      start_server(fn socket, _parent ->
        recv_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\n",
            large_headers,
            "Content-Length: 0\r\nConnection: close\r\n\r\n"
          ])
      end)

    assert {:error, :headers_too_large} =
             HTTPFetchTransport.get(url, [], transport_options(1))

    await_server(server)
  end

  test "header accounting accepts exactly 64 KiB and rejects one byte more" do
    exact_headers = [{"x", :binary.copy("v", 65_531)}]
    over_headers = [{"x", :binary.copy("v", 65_532)}]

    assert HTTPFetchTransport.header_bytes(exact_headers) == 65_536
    assert :ok = HTTPFetchTransport.validate_response_headers(exact_headers)

    assert HTTPFetchTransport.header_bytes(over_headers) == 65_537

    assert {:error, :headers_too_large} =
             HTTPFetchTransport.validate_response_headers(over_headers)
  end

  test "normalizes connection failure and receive timeout" do
    {:ok, listener} = listen()
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, :connection_failed} =
             HTTPFetchTransport.get("http://127.0.0.1:#{port}/", [],
               receive_timeout: 100,
               max_body_size: 32
             )

    {url, server} =
      start_server(fn socket, parent ->
        recv_request(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")
        send(parent, {:headers_sent, self()})

        receive do
          :close -> :ok
        end
      end)

    task =
      Task.async(fn ->
        HTTPFetchTransport.get(url, [],
          receive_timeout: 25,
          max_body_size: 32
        )
      end)

    assert_receive {:headers_sent, server_pid}
    assert {:error, :timeout} = Task.await(task, 1_000)
    send(server_pid, :close)
    await_server(server)
  end

  test "rejects malformed options and request arguments without raising" do
    assert {:error, :invalid_options} = HTTPFetchTransport.get("http://example.com", [], [])

    assert {:error, :invalid_options} =
             HTTPFetchTransport.get("http://example.com", [],
               receive_timeout: 0,
               max_body_size: 1
             )

    assert {:error, :invalid_options} =
             HTTPFetchTransport.get("http://example.com", [],
               receive_timeout: 1,
               max_body_size: -1
             )

    assert {:error, :invalid_options} =
             HTTPFetchTransport.get("http://example.com", [],
               receive_timeout: 1,
               max_body_size: 1,
               unknown: :value
             )

    assert {:error, :invalid_url} =
             HTTPFetchTransport.get("not a URL", [],
               receive_timeout: 1,
               max_body_size: 1
             )

    assert {:error, :invalid_headers} =
             HTTPFetchTransport.get("http://example.com", [{:authorization, "secret"}],
               receive_timeout: 1,
               max_body_size: 1
             )

    for invalid_url <- [
          "http://user@example.com/rules",
          "http://example.com/rules#fragment",
          "http://exa mple.com/rules",
          "http://example.com/bad path",
          "http://example.com:0/rules",
          "http://example.com:65536/rules",
          "http://example.com/\nsecret"
        ] do
      assert {:error, :invalid_url} =
               HTTPFetchTransport.get(invalid_url, [], transport_options(1))
    end

    for invalid_headers <- [
          [{"bad header", "value"}],
          [{"bad:header", "value"}],
          [{"x-test", "line\r\ninjection"}],
          [{"x-test", <<0, 1>>}]
        ] do
      assert {:error, :invalid_headers} =
               HTTPFetchTransport.get(
                 "http://example.com/rules",
                 invalid_headers,
                 transport_options(1)
               )
    end
  end

  test "rejects Content-Length before waiting for the body and closes the socket" do
    {url, server} =
      start_server(fn socket, parent ->
        recv_request(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n")
        send(parent, {:peer_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

    assert {:error, :body_too_large} = HTTPFetchTransport.get(url, [], transport_options(5))
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
    await_server(server)
  end

  test "returns redirects without contacting their destination" do
    {url, server} =
      start_server(fn socket, _parent ->
        recv_request(socket)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/secret\r\nContent-Length: 0\r\n\r\n"
          )
      end)

    assert {:ok, %{status: 302, body: ""}} = HTTPFetchTransport.get(url, [], transport_options(5))
    await_server(server)
  end

  test "preserves compressed wire bytes without decoding" do
    body = :zlib.gzip("raw rule source")

    {url, server} =
      start_server(fn socket, _parent ->
        recv_request(socket)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Length: #{byte_size(body)}\r\n\r\n",
            body
          ])
      end)

    assert {:ok, %{body: ^body}} = HTTPFetchTransport.get(url, [], transport_options(100))
    await_server(server)
  end

  test "transport response contract requires a positive HTTP status" do
    assert {:ok, types} = Code.Typespec.fetch_types(Transport)

    assert {:type, {:response, response_type, []}} =
             Enum.find(types, fn
               {:type, {:response, _definition, []}} -> true
               _type -> false
             end)

    assert Enum.any?(typespec_nodes(response_type), &match?({:type, _, :pos_integer, []}, &1))
    refute Enum.any?(typespec_nodes(response_type), &match?({:type, _, :non_neg_integer, []}, &1))
  end

  test "header boundary failures are finite transport and operational reasons" do
    assert transport_error_atoms() == MapSet.new(Transport.error_reasons())

    assert Snapshot.valid_operational_error?(%{
             kind: :remote,
             reason: :headers_too_large
           })

    assert Snapshot.valid_operational_error?(%{kind: :remote, reason: :invalid_headers})
  end

  defp start_server(handler) do
    parent = self()
    {:ok, listener} = listen()
    {:ok, port} = :inet.port(listener)

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)

        try do
          handler.(socket, parent)
        after
          :gen_tcp.close(socket)
          :gen_tcp.close(listener)
        end
      end)

    {"http://127.0.0.1:#{port}/rules", pid}
  end

  defp listen do
    :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])
  end

  defp recv_request(socket) do
    {:ok, request} = :gen_tcp.recv(socket, 0, 1_000)
    assert request =~ "GET /rules HTTP/1.1"
  end

  defp transport_options(max_body_size) do
    [receive_timeout: 1_000, max_body_size: max_body_size]
  end

  defp header_value(headers, expected_name) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == expected_name, do: value
    end)
  end

  defp transport_error_atoms do
    assert {:ok, types} = Code.Typespec.fetch_types(Transport)

    assert {:type, {:error_reason, definition, []}} =
             Enum.find(types, fn
               {:type, {:error_reason, _definition, []}} -> true
               _type -> false
             end)

    definition
    |> typespec_nodes()
    |> Enum.reduce(MapSet.new(), fn
      {:atom, _line, atom}, atoms -> MapSet.put(atoms, atom)
      _node, atoms -> atoms
    end)
  end

  defp await_server(pid) do
    ref = Process.monitor(pid)

    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  defp typespec_nodes(term) when is_tuple(term) do
    [term | term |> Tuple.to_list() |> Enum.flat_map(&typespec_nodes/1)]
  end

  defp typespec_nodes(term) when is_list(term), do: Enum.flat_map(term, &typespec_nodes/1)
  defp typespec_nodes(_term), do: []
end
