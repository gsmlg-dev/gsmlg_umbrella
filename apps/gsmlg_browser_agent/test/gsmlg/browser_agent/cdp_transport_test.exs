defmodule GSMLG.BrowserAgent.CDPTransportTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.CDP.Transport.HTTPWebSocket

  setup_all do
    {:ok, _started} = Application.ensure_all_started(:telemetry)
    :ok
  end

  @telemetry_events [
    [:http_web_socket, :connect, :start],
    [:http_web_socket, :connect, :stop],
    [:http_web_socket, :connect, :exception],
    [:http_web_socket, :message, :received],
    [:http_web_socket, :message, :sent],
    [:http_web_socket, :close, :start],
    [:http_web_socket, :close, :stop]
  ]

  test "connect telemetry never receives the raw CDP target URL" do
    sentinel = "connect-profile-secret"
    {url, _server} = start_websocket_server(:idle, sentinel)
    attach_transport_telemetry(sentinel)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), transport_opts())
    assert_receive {:server_request, request}, 1_000
    assert request =~ "authorization: bearer secret"
    assert_receive_event(socket, :open)

    refute_telemetry_leak(sentinel)
    assert :ok = HTTPWebSocket.close(socket)
  end

  test "message telemetry never receives the raw CDP target URL" do
    sentinel = "message-profile-secret"
    {url, _server} = start_websocket_server({:send_text, ~s({"id":1,"result":{}})}, sentinel)
    attach_transport_telemetry(sentinel)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), transport_opts())
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert :ok = HTTPWebSocket.send(socket, ~s({"id":1,"method":"Page.enable"}))
    assert_receive_event(socket, {:text, ~s({"id":1,"result":{}})})

    refute_telemetry_leak(sentinel)
    assert :ok = HTTPWebSocket.close(socket)
  end

  test "preserves a first frame coalesced with the upgrade response" do
    sentinel = "coalesced-profile-secret"
    payload = ~s({"id":1,"result":{"coalesced":true}})
    {url, _server} = start_websocket_server({:coalesced_text, payload}, sentinel)
    attach_transport_telemetry(sentinel)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), transport_opts())
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert_receive_event(socket, {:text, payload})

    refute_telemetry_leak(sentinel)
    assert :ok = HTTPWebSocket.close(socket)
  end

  test "close telemetry never receives the raw CDP target URL" do
    sentinel = "close-profile-secret"
    {url, _server} = start_websocket_server(:reply_close, sentinel)
    attach_transport_telemetry(sentinel)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), transport_opts())
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert :ok = HTTPWebSocket.close(socket)
    assert_receive_event(socket, {:close, 1_000})

    refute_telemetry_leak(sentinel)
  end

  test "error handling telemetry never receives the raw CDP target URL" do
    sentinel = "error-profile-secret"
    {url, _server} = start_websocket_server(:send_malformed_frame, sentinel)
    attach_transport_telemetry(sentinel)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), transport_opts())
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert_receive_event(socket, :error)

    refute_telemetry_leak(sentinel)
  end

  test "incoming messages remain bounded" do
    payload = String.duplicate("x", 33)
    {url, _server} = start_websocket_server({:send_text, payload}, "bounded-receive")
    opts = Keyword.put(transport_opts(), :max_message_bytes, 32)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), opts)
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert_receive_event(socket, :error)
  end

  test "outgoing messages remain bounded" do
    {url, _server} = start_websocket_server(:idle, "bounded-send")
    opts = Keyword.put(transport_opts(), :max_send_queue_bytes, 32)

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), self(), opts)
    assert_receive {:server_request, _request}, 1_000
    assert_receive_event(socket, :open)
    assert {:error, :send_queue_full} = HTTPWebSocket.send(socket, String.duplicate("x", 33))
  end

  test "the private connection stops when its owner exits" do
    owner = spawn(fn -> Process.sleep(:infinity) end)
    {url, _server} = start_websocket_server(:idle, "owner-lifecycle")

    assert {:ok, socket} = HTTPWebSocket.connect(url, auth_headers(), owner, transport_opts())
    assert_receive {:server_request, _request}, 1_000
    monitor = Process.monitor(socket)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^monitor, :process, ^socket, _reason}, 1_000
  end

  defp start_websocket_server(script, sentinel) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        active: false,
        packet: :raw,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)
    parent = self()

    server =
      spawn(fn ->
        with {:ok, socket} <- :gen_tcp.accept(listener),
             {:ok, request} <- recv_headers(socket, <<>>),
             :ok <- send_upgrade_response(socket, request, upgrade_suffix(script)) do
          send(parent, {:server_request, String.downcase(request)})
          run_server_script(socket, script)
          :gen_tcp.close(socket)
        end
      end)

    on_exit(fn ->
      Process.exit(server, :kill)
      :gen_tcp.close(listener)
    end)

    url =
      "ws://127.0.0.1:#{port}/api/profiles/#{sentinel}/cdp/devtools/page/opaque-target"

    {url, server}
  end

  defp recv_headers(socket, buffer) when byte_size(buffer) <= 16_384 do
    if String.contains?(buffer, "\r\n\r\n") do
      {:ok, buffer}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0, 1_000) do
        recv_headers(socket, buffer <> data)
      end
    end
  end

  defp recv_headers(_socket, _buffer), do: {:error, :headers_too_large}

  defp send_upgrade_response(socket, request, suffix) do
    with [_, key] <- Regex.run(~r/sec-websocket-key:\s*([^\r\n]+)/i, request) do
      accept =
        :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\n" <>
          "upgrade: websocket\r\n" <>
          "connection: Upgrade\r\n" <>
          "sec-websocket-accept: #{accept}\r\n\r\n" <> suffix
      )
    else
      _missing_key -> {:error, :missing_websocket_key}
    end
  end

  defp upgrade_suffix({:coalesced_text, payload}), do: text_frame(payload)
  defp upgrade_suffix(_script), do: ""

  defp run_server_script(socket, :idle) do
    _ = :gen_tcp.recv(socket, 0, 1_000)
    :ok
  end

  defp run_server_script(socket, {:send_text, payload}) do
    :ok = :gen_tcp.send(socket, text_frame(payload))
    _ = :gen_tcp.recv(socket, 0, 2_000)
    _ = :gen_tcp.recv(socket, 0, 2_000)
    :ok
  end

  defp run_server_script(socket, {:coalesced_text, _payload}) do
    _ = :gen_tcp.recv(socket, 0, 2_000)
    :ok
  end

  defp run_server_script(socket, :reply_close) do
    with {:ok, _frame} <- :gen_tcp.recv(socket, 0, 1_000) do
      :gen_tcp.send(socket, <<0x88, 2, 1_000::16>>)
    end
  end

  defp run_server_script(socket, :send_malformed_frame) do
    :ok = :gen_tcp.send(socket, <<0x83, 0>>)
    Process.sleep(50)
  end

  defp text_frame(payload) when byte_size(payload) <= 125,
    do: <<0x81, byte_size(payload), payload::binary>>

  defp attach_transport_telemetry(sentinel) do
    handler_id = "cdp-transport-no-raw-url-#{sentinel}-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        @telemetry_events,
        &__MODULE__.handle_transport_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_transport_telemetry(event, _measurements, metadata, pid) do
    send(pid, {:transport_telemetry, event, metadata})
  end

  defp refute_telemetry_leak(sentinel) do
    events = Process.delete(:stashed_transport_telemetry) || []
    events = collect_transport_telemetry(Enum.reverse(events))

    refute Enum.any?(events, fn {event, metadata} ->
             String.contains?(inspect({event, metadata}), sentinel)
           end),
           "raw CDP target URL reached transport telemetry: #{inspect(events)}"
  end

  defp collect_transport_telemetry(events) do
    receive do
      {:transport_telemetry, event, metadata} ->
        collect_transport_telemetry([{event, metadata} | events])
    after
      50 -> Enum.reverse(events)
    end
  end

  defp assert_receive_event(socket, expected) do
    deadline = System.monotonic_time(:millisecond) + 2_000
    assert expected == await_transport_event(socket, expected, deadline, [])
  end

  defp await_transport_event(socket, expected, deadline, seen) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:transport_telemetry, event, metadata} ->
        stashed = Process.get(:stashed_transport_telemetry, [])
        Process.put(:stashed_transport_telemetry, [{event, metadata} | stashed])
        await_transport_event(socket, expected, deadline, seen)

      message ->
        case normalize_transport_event(message, socket) do
          :open when expected == :open -> :open
          {:error, _reason} when expected == :error -> :error
          {:text, payload} when expected == {:text, payload} -> expected
          {:close, code} when expected == {:close, code} -> expected
          other -> await_transport_event(socket, expected, deadline, [other | seen])
        end
    after
      remaining ->
        flunk(
          "timed out waiting for transport event #{inspect(expected)}; " <>
            "observed #{inspect(Enum.reverse(seen))}"
        )
    end
  end

  defp normalize_transport_event({:cdp_transport, socket, event}, socket), do: event

  defp normalize_transport_event({_module, socket, %{__struct__: struct} = event}, socket) do
    case struct |> Module.split() |> List.last() do
      "Open" -> :open
      "Message" -> {:text, Map.fetch!(event, :data)}
      "Error" -> {:error, Map.get(event, :reason)}
      "Close" -> {:close, Map.get(event, :code)}
      _other -> :unknown
    end
  end

  defp normalize_transport_event(_message, _socket), do: :unknown

  defp auth_headers, do: [{"authorization", "Bearer secret"}]

  defp transport_opts do
    [
      connect_timeout: 500,
      handshake_timeout: 500,
      max_message_bytes: 2_048,
      max_send_queue_bytes: 2_048
    ]
  end
end
