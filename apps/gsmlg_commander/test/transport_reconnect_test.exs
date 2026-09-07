defmodule GSMLG.Commander.TransportReconnectTest do
  use ExUnit.Case, async: false

  defmodule RecordingTransport do
    @behaviour Phoenix.SocketClient.Transport

    @impl true
    def open(url, opts) do
      owner = Keyword.fetch!(opts, :test_owner)
      sender = Keyword.fetch!(opts, :sender)
      headers = Keyword.fetch!(opts, :headers)

      :ok = HTTP.WebSocket.Telemetry.connect_start(URI.parse(url))

      pid =
        spawn_link(fn ->
          send(owner, {:transport_opened, url, headers, self()})
          send(sender, {:connected, self()})
          loop(sender)
        end)

      {:ok, pid}
    end

    @impl true
    def close(pid) do
      send(pid, :stop)
      :ok
    end

    defp loop(sender) do
      receive do
        :disconnect ->
          send(sender, {:disconnected, :test_disconnect, self()})
          loop(sender)

        :stop ->
          :ok
      end
    end
  end

  test "a socket reconnect authenticates with fresh headers and never exposes them in URL telemetry" do
    secret = "fresh-reconnect-secret"
    name = "node-reconnect-secret"
    credential_id = "credential-reconnect-secret"
    handler_id = "http-websocket-url-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:http_web_socket, :connect, :start],
      fn _event, _measurements, metadata, pid ->
        send(pid, {:http_websocket_telemetry, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    opts =
      GSMLG.Commander.socket_opts(
        platform_url: "wss://control.example.test/commander-socket/websocket",
        platform_key: secret,
        name: name,
        credential_id: credential_id,
        tls: [enabled: false]
      )

    transport_opts =
      opts
      |> Keyword.fetch!(:transport_opts)
      |> Keyword.merge(delegate_transport: RecordingTransport, test_owner: self())

    socket_name = :"reconnect_socket_#{System.unique_integer([:positive])}"

    socket =
      start_supervised!(
        {Phoenix.SocketClient,
         Keyword.merge(opts,
           name: socket_name,
           auto_connect: false,
           reconnect_interval: 5,
           transport_opts: transport_opts
         )}
      )

    assert :ok = Phoenix.SocketClient.connect(socket)
    assert_receive {:transport_opened, first_url, first_headers, first_transport}
    assert_receive {:http_websocket_telemetry, first_metadata}

    send(first_transport, :disconnect)
    assert_receive {:transport_opened, second_url, second_headers, _second_transport}, 250
    assert_receive {:http_websocket_telemetry, second_metadata}

    first = auth_headers(first_headers)
    second = auth_headers(second_headers)

    assert first["nonce"] != second["nonce"]
    assert_valid_signature(first, secret)
    assert_valid_signature(second, secret)

    assert query(first_url) == %{"vsn" => "2.0.0"}
    assert query(second_url) == %{"vsn" => "2.0.0"}

    for value <- Map.values(first) ++ Map.values(second) do
      refute URI.to_string(first_metadata.url) =~ value
      refute URI.to_string(second_metadata.url) =~ value
    end

    refute URI.to_string(first_metadata.url) =~ name
    refute URI.to_string(first_metadata.url) =~ credential_id
    refute inspect(Phoenix.SocketClient.get_state(socket)) =~ secret
  end

  defp query(url), do: url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

  defp auth_headers(headers) do
    Map.new(headers, fn
      {"x-commander-signature", value} -> {"signature", value}
      {"x-commander-name", value} -> {"name", value}
      {"x-commander-credential-id", value} -> {"credential_id", value}
      {"x-commander-sign-at", value} -> {"sign_at", value}
      {"x-commander-nonce", value} -> {"nonce", value}
    end)
  end

  defp assert_valid_signature(params, secret) do
    payload =
      GSMLG.Commander.signature_payload(
        params["credential_id"],
        params["name"],
        params["sign_at"],
        params["nonce"]
      )

    expected = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    assert params["signature"] == expected
  end
end
