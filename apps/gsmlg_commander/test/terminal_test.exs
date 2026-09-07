defmodule GSMLG.Commander.TerminalTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

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

  test "keeps registration and heartbeat off the PTY compatibility channel" do
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

    refute_receive {:push, :terminal_channel, "message", %{type: "register"}}, 30
    refute_receive {:push, :terminal_channel, "message", %{type: "heartbeat"}}, 30

    assert Process.alive?(pid)
  end

  test "rejoins the PTY compatibility channel after the socket client terminates it" do
    test_pid = self()

    join_fun = fn _socket, topic ->
      channel = spawn(fn -> Process.sleep(:infinity) end)
      send(test_pid, {:joined_channel, topic, channel})
      {:ok, %{}, channel}
    end

    start_supervised!(
      {Terminal,
       socket: :commander_socket,
       name: "dev-agent",
       join_fun: join_fun,
       push_fun: fn _, _, _ -> :ok end,
       reconnect_after: 10}
    )

    assert_receive {:joined_channel, "terminal:dev-agent", first_channel}
    Process.exit(first_channel, :kill)
    assert_receive {:joined_channel, "terminal:dev-agent", replacement}, 100
    assert replacement != first_channel
  end

  test "normalizes unhandled messages without retaining their contents" do
    secret = "TERMINAL-UNHANDLED-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "terminal-unhandled-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    terminal =
      start_supervised!(
        {Terminal,
         socket: :commander_socket,
         name: "dev-agent",
         join_fun: fn _, _ -> {:ok, %{}, :terminal_channel} end,
         push_fun: fn _, _, _ -> :ok end}
      )

    log =
      capture_log([level: :debug], fn ->
        send(terminal, {:unexpected_remote_message, secret})

        assert_receive {:terminal_log,
                        %{
                          message: "Unhandled message in Terminal channel",
                          message_code: :unknown,
                          message_size: message_size
                        } = metadata},
                       500

        assert message_size > 0
        refute inspect(metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "normalizes invalid channel payload telemetry without retaining type or body" do
    secret = "TERMINAL-PAYLOAD-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "terminal-invalid-payload-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    terminal =
      start_supervised!(
        {Terminal,
         socket: :commander_socket,
         name: "dev-agent",
         join_fun: fn _, _ -> {:ok, %{}, :terminal_channel} end,
         push_fun: fn _, _, _ -> :ok end}
      )

    payload = %{"type" => secret, "body" => secret}

    log =
      capture_log([level: :debug], fn ->
        send(terminal, {:phoenix_channel_message, "message", payload})

        assert_receive {:terminal_log,
                        %{
                          message: "Received message on Terminal channel",
                          message_code: :unknown,
                          payload_size: payload_size
                        } = received_metadata},
                       500

        assert payload_size > 0
        refute inspect(received_metadata) =~ secret

        assert_receive {:terminal_log,
                        %{
                          message: "Failed to parse message",
                          message_code: :unknown,
                          error_code: :unknown_message_type,
                          payload_size: ^payload_size
                        } = invalid_metadata},
                       500

        refute inspect(invalid_metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "normalizes join responses and transport reasons without retaining their contents" do
    secret = "TERMINAL-TRANSPORT-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "terminal-transport-log-#{System.unique_integer([:positive])}"
    {:ok, joins} = Agent.start_link(fn -> 0 end)

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        terminal =
          start_supervised!(
            {Terminal,
             socket: :commander_socket,
             name: "dev-agent",
             join_fun: fn _, _ ->
               case Agent.get_and_update(joins, &{&1, &1 + 1}) do
                 0 -> {:ok, %{"response" => secret}, :terminal_channel}
                 _ -> {:error, {:remote_join_error, secret}}
               end
             end,
             push_fun: fn _, _, _ -> :ok end,
             reconnect_after: 60_000}
          )

        assert_receive {:terminal_log,
                        %{
                          message: "Terminal channel joined successfully",
                          response_code: :joined,
                          response_size: response_size
                        } = joined_metadata},
                       500

        assert response_size > 0
        refute inspect(joined_metadata) =~ secret

        send(terminal, {:phoenix_channel_join, {:error, {:remote_join_error, secret}}})

        assert_receive {:terminal_log,
                        %{
                          message: "Failed to join Terminal channel",
                          error_code: :transport_error,
                          reason_size: reason_size
                        } = join_error_metadata},
                       500

        assert reason_size > 0
        refute inspect(join_error_metadata) =~ secret

        send(terminal, {:phoenix_channel_leave, {:remote_leave, secret}})

        assert_receive {:terminal_log,
                        %{
                          message: "Terminal channel left",
                          reason_code: :transport_error,
                          reason_size: leave_reason_size
                        } = leave_metadata},
                       500

        assert leave_reason_size > 0
        refute inspect(leave_metadata) =~ secret

        send(terminal, :reconnect)

        assert_receive {:terminal_log,
                        %{
                          message: "Failed to join Terminal channel",
                          error_code: :transport_error,
                          reason_size: retry_reason_size
                        } = retry_metadata},
                       500

        assert retry_reason_size > 0
        refute inspect(retry_metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "logs PTY creation using sizes, hashed session correlation, and fixed errors" do
    start_supervised!({Registry, keys: :unique, name: GSMLG.Commander.LocalSessionRegistry})
    start_supervised!({SessionManager, []})

    secret = "PTY-COMMAND-SECRET-#{System.unique_integer([:positive])}"
    command = secret <> String.duplicate("x", 10_001)
    session_id = "#{secret}-session"
    expected_hash = :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    handler_id = "terminal-pty-create-log-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    terminal =
      start_supervised!(
        {Terminal,
         socket: :commander_socket,
         name: "dev-agent",
         join_fun: fn _, _ -> {:ok, %{}, :terminal_channel} end,
         push_fun: fn _, _, _ -> :ok end}
      )

    log =
      capture_log(fn ->
        send(terminal, {
          :phoenix_channel_message,
          "message",
          %{"type" => "create_pty", "session_id" => session_id, "command" => command}
        })

        assert_receive {:terminal_log,
                        %{
                          message: "Creating PTY session",
                          command_size: command_size,
                          session_id_hash: ^expected_hash,
                          session_id_size: session_id_size
                        } = creating_metadata},
                       500

        assert command_size == byte_size(command)
        assert session_id_size == byte_size(session_id)
        refute inspect(creating_metadata) =~ secret

        assert_receive {:terminal_log,
                        %{
                          message: "Failed to create PTY session",
                          error_code: :command_too_long,
                          session_id_hash: ^expected_hash
                        } = failed_metadata},
                       500

        refute inspect(failed_metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "drop telemetry allowlists outbound message code without retaining local error reasons" do
    secret = "PTY-LOCAL-REASON-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "terminal-drop-log-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    terminal =
      start_supervised!(
        {Terminal,
         socket: :commander_socket,
         name: "dev-agent",
         join_fun: fn _, _ -> {:error, :socket_not_connected} end,
         reconnect_after: 60_000}
      )

    log =
      capture_log(fn ->
        send(terminal, {
          :pty_error,
          %{session_id: "#{secret}-session", reason: {:local_failure, secret}}
        })

        assert_receive {:terminal_log,
                        %{
                          message: "Terminal channel is not joined; dropping message",
                          message_code: :error,
                          payload_size: payload_size
                        } = metadata},
                       500

        assert payload_size > 0
        refute inspect(metadata) =~ secret
      end)

    refute log =~ secret
  end
end
