defmodule GSMLG.Commander.TerminalTest do
  use ExUnit.Case, async: false

  alias GSMLG.Commander.SessionManager
  alias GSMLG.Commander.Terminal

  test "retries when the initial channel join happens before the socket is connected" do
    test_pid = self()

    join_fun = fn socket, topic ->
      send(test_pid, {:join_attempt, socket, topic})
      {:error, :socket_not_connected}
    end

    start_supervised!(
      {Terminal,
       [
         socket: :commander_socket,
         name: "dev-agent",
         join_fun: join_fun,
         reconnect_after: 10
       ]}
    )

    assert_receive {:join_attempt, :commander_socket, "terminal:dev-agent"}
    assert_receive {:join_attempt, :commander_socket, "terminal:dev-agent"}, 100
  end

  test "sends heartbeat without waiting for a channel reply" do
    test_pid = self()

    start_supervised!({Registry, keys: :unique, name: GSMLG.Commander.LocalSessionRegistry})
    start_supervised!({SessionManager, []})

    join_fun = fn socket, topic ->
      send(test_pid, {:join_attempt, socket, topic})
      {:ok, %{"status" => "connected"}, :terminal_channel}
    end

    push_fun = fn channel, event, message ->
      send(test_pid, {:push, channel, event, message})
      :ok
    end

    pid =
      start_supervised!(
        {Terminal,
         [
           socket: :commander_socket,
           name: "dev-agent",
           join_fun: join_fun,
           push_fun: push_fun,
           heartbeat_interval: 10
         ]}
      )

    assert_receive {:join_attempt, :commander_socket, "terminal:dev-agent"}

    assert_receive {:push, :terminal_channel, "message", %{type: "register"}}

    assert_receive {:push, :terminal_channel, "message",
                    %{type: "heartbeat", active_sessions: 0}},
                   100

    assert Process.alive?(pid)
  end
end
