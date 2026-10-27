defmodule GSMLG.CouchDB.ConnectionTest do
  use ExUnit.Case, async: false

  alias GSMLG.CouchDB.Connection

  setup_all do
    {:ok, _applications} = Application.ensure_all_started(:http_fetch)
    :ok
  end

  setup do
    previous = Application.get_env(:gsmlg_couchdb, Connection)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:gsmlg_couchdb, Connection, previous),
        else: Application.delete_env(:gsmlg_couchdb, Connection)
    end)

    :ok
  end

  test "preserves Basic auth, JSON encoding and response status for raw requests" do
    start_endpoint(fn socket, parent ->
      request = receive_request(socket)
      send(parent, {:request, request})

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: 11\r\nConnection: close\r\n\r\n{\"ok\":true}"
        )
    end)

    assert {:ok, %{status: 201, headers: headers, data: "{\"ok\":true}"}} =
             Connection.request("POST", "/docs", %{name: "Alice"})

    assert {"content-type", "application/json"} in headers
    assert_receive {:request, request}
    assert request =~ "POST /docs HTTP/1.1"

    assert String.downcase(request) =~
             "authorization: basic " <> String.downcase(Base.encode64("admin:secret"))

    assert request =~ "{\"name\":\"Alice\"}"
  end

  test "correlates concurrent requests completing in reverse order" do
    start_endpoint(fn socket, _parent ->
      request = receive_request(socket)
      if request =~ "/slow", do: Process.sleep(75)
      body = if request =~ "/slow", do: "slow", else: "fast"

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\n" <> body
        )
    end)

    slow = Task.async(fn -> Connection.get("/slow") end)
    fast = Task.async(fn -> Connection.get("/fast") end)
    assert {:ok, "fast"} = Task.await(fast)
    assert {:ok, "slow"} = Task.await(slow)
    assert %{requests: requests} = Connection.get_state()
    assert requests == %{}
  end

  test "decodes JSON success and error responses across separate connections" do
    start_endpoint(fn socket, _parent ->
      request = receive_request(socket)

      {status, body} =
        if request =~ "/missing",
          do: {404, "{\"error\":\"not_found\"}"},
          else: {200, "{\"ok\":true}"}

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Status\r\nContent-Type: application/json\r\nContent-Length: #{byte_size(body)}\r\nConnection: close\r\n\r\n" <>
            body
        )
    end)

    assert {:ok, %{ok: true}} = Connection.get("/docs")
    assert {:error, %{error: "not_found"}} = Connection.get("/missing")
  end

  test "returns transport errors and remains available for subsequent requests" do
    pid =
      start_endpoint(fn socket, _parent ->
        receive_request(socket)
        :gen_tcp.close(socket)
      end)

    assert {:error, _reason} = Connection.get("/closed")
    assert Process.alive?(pid)
    assert %{requests: %{}} = Connection.get_state()
  end

  test "shutdown cancels in-flight requests and closes their sockets" do
    pid =
      start_endpoint(fn socket, parent ->
        receive_request(socket)
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n")
        send(parent, :request_waiting)
        send(parent, {:peer_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

    task = Task.async(fn -> Connection.get("/pending") end)
    assert_receive :request_waiting, 1_000
    :ok = GenServer.stop(pid)
    assert {:error, :closed} = Task.await(task)
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
  end

  defp start_endpoint(handler) do
    parent = self()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, port} = :inet.port(listener)
    {:ok, acceptor} = Task.start_link(fn -> accept_connections(listener, handler, parent) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(acceptor), do: Process.exit(acceptor, :kill)
    end)

    Application.put_env(:gsmlg_couchdb, Connection,
      scheme: :http,
      host: "127.0.0.1",
      port: port,
      username: "admin",
      password: "secret"
    )

    start_supervised!({Connection, []}, restart: :temporary)
  end

  defp accept_connections(listener, handler, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, worker} =
          Task.start_link(fn ->
            receive do
              {:socket, socket} ->
                try do
                  handler.(socket, parent)
                after
                  :gen_tcp.close(socket)
                end
            end
          end)

        :ok = :gen_tcp.controlling_process(socket, worker)
        send(worker, {:socket, socket})
        accept_connections(listener, handler, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_request(socket, buffer \\ "") do
    {:ok, data} = :gen_tcp.recv(socket, 0, 1_000)
    buffer = buffer <> data

    case String.split(buffer, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        length =
          case Regex.run(~r/content-length: (\d+)/i, headers) do
            [_, value] -> String.to_integer(value)
            nil -> 0
          end

        if byte_size(body) >= length, do: buffer, else: receive_request(socket, buffer)

      _partial ->
        receive_request(socket, buffer)
    end
  end
end
