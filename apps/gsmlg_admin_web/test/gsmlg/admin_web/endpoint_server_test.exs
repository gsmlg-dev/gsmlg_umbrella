defmodule GSMLG.AdminWeb.EndpointServerTest do
  use ExUnit.Case, async: false

  alias HTTP.WebSocket
  alias HTTP.WebSocket.Event.{Error, Message, Open}

  test "public and admin endpoints own independent Gaoxy listeners and stop them cleanly" do
    ports =
      for endpoint <- [GSMLG.Web.Endpoint, GSMLG.AdminWeb.Endpoint] do
        assert endpoint.config(:adapter) == Gaoxy.PhoenixAdapter

        [listener] =
          Gaoxy.PhoenixAdapter.child_specs(endpoint,
            server: true,
            http: [ip: {127, 0, 0, 1}, port: 0]
          )

        start_supervised!(listener)
        assert {:ok, {{127, 0, 0, 1}, port}} = Gaoxy.PhoenixAdapter.server_info(endpoint, :http)
        assert port > 0
        {endpoint, port}
      end

    [{GSMLG.Web.Endpoint, public_port}, {GSMLG.AdminWeb.Endpoint, admin_port}] = ports
    refute public_port == admin_port

    public_response = request(public_port, "/robots.txt")
    assert public_response =~ "HTTP/1.1 200 OK"
    assert public_response =~ "User-agent:"

    admin_response = request(admin_port, "/gao_notes/notes")
    assert admin_response =~ "HTTP/1.1 302 Found"
    assert admin_response =~ "/sign_in"

    for {_endpoint, port} <- ports do
      assert_websocket_heartbeat(port, "/live/websocket")
    end

    assert_websocket_heartbeat(admin_port, "/commander-socket/websocket", commander_headers())

    socket = websocket(admin_port, "/commander-socket/websocket", [])
    monitor = Process.monitor(socket.pid)

    try do
      assert_receive {WebSocket, ^socket, %Error{reason: {:unexpected_status, 403}}}, 2_000
    after
      WebSocket.close(socket)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    end

    for {endpoint, _port} <- ports do
      stop_supervised!({Gaoxy.PhoenixAdapter, endpoint})
      assert {:error, :not_running} = Gaoxy.PhoenixAdapter.server_info(endpoint, :http)
    end
  end

  defp assert_websocket_heartbeat(port, path, headers \\ []) do
    socket = websocket(port, path, headers)
    monitor = Process.monitor(socket.pid)

    try do
      assert_receive {WebSocket, ^socket, %Open{}}, 2_000
      heartbeat = [nil, "heartbeat", "phoenix", "heartbeat", %{}]
      assert :ok = WebSocket.send(socket, Jason.encode!(heartbeat))
      assert_receive {WebSocket, ^socket, %Message{data: response}}, 2_000

      assert Jason.decode!(response) ==
               [nil, "heartbeat", "phoenix", "phx_reply", %{"status" => "ok", "response" => %{}}]
    after
      WebSocket.close(socket)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 2_000
    end
  end

  defp websocket(port, path, headers) do
    socket =
      WebSocket.new("ws://localhost:#{port}#{path}?vsn=2.0.0", [],
        headers: headers,
        opening_timeout: 2_000,
        close_timeout: 1_000
      )

    assert %WebSocket{} = socket
    socket
  end

  defp commander_headers do
    original = Application.fetch_env(:gsmlg_commander, GSMLG.Commander)
    secret = :crypto.strong_rand_bytes(32)
    name = "endpoint-wire"
    credential_id = "endpoint-wire-credential"

    Application.put_env(:gsmlg_commander, GSMLG.Commander,
      platform_credentials: %{credential_id => %{key: secret, commander_name: name}},
      auth_timestamp_window_seconds: 30
    )

    on_exit(fn ->
      case original do
        {:ok, config} -> Application.put_env(:gsmlg_commander, GSMLG.Commander, config)
        :error -> Application.delete_env(:gsmlg_commander, GSMLG.Commander)
      end
    end)

    sign_at = Integer.to_string(System.system_time(:second))
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

    signature =
      :crypto.mac(:hmac, :sha256, secret, "v1\n#{credential_id}\n#{name}\n#{sign_at}\n#{nonce}")
      |> Base.encode16(case: :lower)

    [
      {"x-commander-name", name},
      {"x-commander-credential-id", credential_id},
      {"x-commander-sign-at", sign_at},
      {"x-commander-nonce", nonce},
      {"x-commander-signature", signature}
    ]
  end

  defp request(port, path) do
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 2_000)

    try do
      :ok =
        :gen_tcp.send(
          socket,
          "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
        )

      receive_response(socket, "")
    after
      :gen_tcp.close(socket)
    end
  end

  defp receive_response(socket, response) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} -> receive_response(socket, response <> bytes)
      {:error, :closed} -> response
    end
  end
end
