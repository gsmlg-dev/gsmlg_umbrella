defmodule GSMLG.ProxyRules.Transport.FinchTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Transport
  alias GSMLG.ProxyRules.Transport.Finch, as: FinchTransport

  setup do
    finch_name = String.to_atom("proxy_rules_finch_#{System.unique_integer([:positive])}")
    start_supervised!({Finch, name: finch_name})
    %{finch_name: finch_name}
  end

  test "streams a small chunked response and preserves binary headers", %{finch_name: finch_name} do
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
             FinchTransport.get(url, [{"accept", "text/plain"}],
               finch_name: finch_name,
               receive_timeout: 1_000,
               max_body_size: 32
             )

    assert_receive :request_received

    assert Enum.any?(headers, fn {name, value} ->
             String.downcase(name) == "x-mixed-case" and value == "Value"
           end)

    await_server(server)
  end

  test "halts an oversized chunked response before the server releases the remainder", %{
    finch_name: finch_name
  } do
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
             FinchTransport.get(url, [],
               finch_name: finch_name,
               receive_timeout: 1_000,
               max_body_size: 5
             )

    assert_receive {:oversized_chunk_sent, server_pid}
    assert Process.alive?(server_pid)
    send(server_pid, :release_remainder)
    await_server(server)
  end

  test "supports content-length bodies and empty 204 and 304 responses", %{
    finch_name: finch_name
  } do
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
               FinchTransport.get(url, [],
                 finch_name: finch_name,
                 receive_timeout: 1_000,
                 max_body_size: 32
               )

      await_server(server)
    end
  end

  test "normalizes connection failure and receive timeout", %{finch_name: finch_name} do
    {:ok, listener} = listen()
    {:ok, port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)

    assert {:error, :connection_failed} =
             FinchTransport.get("http://127.0.0.1:#{port}/", [],
               finch_name: finch_name,
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
        FinchTransport.get(url, [],
          finch_name: finch_name,
          receive_timeout: 25,
          max_body_size: 32
        )
      end)

    assert_receive {:headers_sent, server_pid}
    assert {:error, :receive_timeout} = Task.await(task, 1_000)
    send(server_pid, :close)
    await_server(server)
  end

  test "rejects malformed options and request arguments without raising", %{
    finch_name: finch_name
  } do
    assert {:error, :invalid_options} = FinchTransport.get("http://example.com", [], [])

    assert {:error, :invalid_options} =
             FinchTransport.get("http://example.com", [],
               finch_name: finch_name,
               receive_timeout: 0,
               max_body_size: 1
             )

    assert {:error, :invalid_options} =
             FinchTransport.get("http://example.com", [],
               finch_name: finch_name,
               receive_timeout: 1,
               max_body_size: -1
             )

    assert {:error, :invalid_options} =
             FinchTransport.get("http://example.com", [],
               finch_name: finch_name,
               receive_timeout: 1,
               max_body_size: 1,
               unknown: :value
             )

    assert {:error, :invalid_url} =
             FinchTransport.get("not a URL", [],
               finch_name: finch_name,
               receive_timeout: 1,
               max_body_size: 1
             )

    assert {:error, :invalid_headers} =
             FinchTransport.get("http://example.com", [{:authorization, "secret"}],
               finch_name: finch_name,
               receive_timeout: 1,
               max_body_size: 1
             )
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

  defp start_server(handler) do
    parent = self()
    {:ok, listener} = listen()
    {:ok, port} = :inet.port(listener)

    {:ok, pid} =
      Task.start_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 1_000)

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
