defmodule GSMLG.CommanderTest.Client.AgentConnectionTest do
  use ExUnit.Case, async: true

  alias GSMLG.CommanderTest.Client.AgentConnection

  test "depends on http_web_socket" do
    deps =
      GSMLG.CommanderTest.MixProject.project()
      |> Keyword.fetch!(:deps)
      |> Enum.map(&elem(&1, 0))

    assert :http_web_socket in deps
  end

  test "bridges HTTP.WebSocket events and sends JSON frames" do
    {:ok, pid} =
      AgentConnection.connect("ws://example.test/agent", "secret token", self(),
        web_socket_client: __MODULE__.FakeWebSocket,
        web_socket_options: [test_pid: self()]
      )

    assert_receive {:web_socket_new, "ws://example.test/agent?token=secret+token", [],
                    [owner: ^pid, test_pid: _]}

    send(pid, {HTTP.WebSocket, :fake_socket, %HTTP.WebSocket.Event.Open{}})

    assert_receive {:web_socket_send, auth_payload}

    assert %{
             "type" => "auth",
             "token" => "secret token",
             "capabilities" => capabilities,
             "hostname" => hostname
           } = Jason.decode!(auth_payload)

    assert "shell" in capabilities
    assert is_binary(hostname)

    send(
      pid,
      {HTTP.WebSocket, :fake_socket,
       %HTTP.WebSocket.Event.Message{data: ~s({"type":"heartbeat","interval":30})}}
    )

    assert_receive {:ws_message, %{"type" => "heartbeat", "interval" => 30}}

    assert :ok = AgentConnection.send_heartbeat_response(pid)
    assert_receive {:web_socket_send, heartbeat_payload}
    assert %{"type" => "heartbeat_response"} = Jason.decode!(heartbeat_payload)

    assert :ok = AgentConnection.disconnect(pid)
    assert_receive {:web_socket_close, _socket}
  end

  defmodule FakeWebSocket do
    import Kernel, except: [send: 2]

    def new(url, protocols, options) do
      Kernel.send(Keyword.fetch!(options, :test_pid), {:web_socket_new, url, protocols, options})
      %{test_pid: Keyword.fetch!(options, :test_pid)}
    end

    def send(socket, payload) do
      Kernel.send(socket.test_pid, {:web_socket_send, payload})
      :ok
    end

    def close(socket) do
      Kernel.send(socket.test_pid, {:web_socket_close, socket})
      :ok
    end
  end
end
