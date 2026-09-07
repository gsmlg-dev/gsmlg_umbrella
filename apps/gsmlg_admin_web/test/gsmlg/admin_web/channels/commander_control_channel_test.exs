defmodule GSMLG.AdminWeb.CommanderControlChannelTest do
  use GSMLG.AdminWeb.ChannelCase, async: false

  import ExUnit.CaptureLog

  alias GSMLG.CommandPlatform.{AgentRegistry, CommandDispatcher}
  alias GSMLG.AdminWeb.{CommanderChannel, CommanderSocket, TerminalChannel}

  test "binds the control topic to the authenticated socket identity" do
    socket =
      socket(CommanderSocket, "commander-node-a", %{name: "node-a", commander_name: "node-a"})

    assert {:error, %{reason: "identity_mismatch"}} =
             subscribe_and_join(socket, CommanderChannel, "commander:node-b")

    assert {:ok, _reply, joined} =
             subscribe_and_join(socket, CommanderChannel, "commander:node-a")

    assert {:error, :not_found} = AgentRegistry.find_agent("node-a")

    ref = push(joined, "message", negotiation())
    assert_reply ref, :ok, %{capabilities: 1}, 500
    assert {:ok, %{channel_pid: channel_pid}} = AgentRegistry.find_agent("node-a")
    assert channel_pid == joined.channel_pid
  end

  test "invalid negotiation never exposes the node as online" do
    socket =
      socket(CommanderSocket, "commander-node-invalid-negotiation", %{
        name: "node-invalid-negotiation",
        commander_name: "node-invalid-negotiation"
      })

    assert {:ok, _reply, joined} =
             subscribe_and_join(
               socket,
               CommanderChannel,
               "commander:node-invalid-negotiation"
             )

    invalid = put_in(negotiation(), ["protocol_version"], 99)
    ref = push(joined, "message", invalid)
    assert_reply ref, :error, %{}, 500
    assert {:error, :not_found} = AgentRegistry.find_agent("node-invalid-negotiation")
  end

  test "a superseded generation cannot renegotiate or mutate heartbeat metadata" do
    name = "node-generation-fence"
    assigns = %{name: name, commander_name: name}

    assert {:ok, _, old} =
             socket(CommanderSocket, "old-generation", assigns)
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    old_ref = push(old, "message", negotiation())
    assert_reply old_ref, :ok, %{capabilities: 1}, 500

    assert {:ok, _, current} =
             socket(CommanderSocket, "current-generation", assigns)
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    current_ref = push(current, "message", negotiation())
    assert_reply current_ref, :ok, %{capabilities: 1}, 500

    heartbeat_ref =
      push(old, "message", %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "timestamp" => "stale-heartbeat",
        "capability_count" => 999
      })

    assert_reply heartbeat_ref, :error, %{reason: "stale_generation"}
    renegotiate_ref = push(old, "message", negotiation())
    assert_reply renegotiate_ref, :error, %{reason: "already_negotiated"}

    stale_response_ref =
      push(old, "message", %{
        "type" => "rpc.response",
        "protocol_version" => 1,
        "request_id" => "00000000-0000-0000-0000-000000000071",
        "result" => %{}
      })

    assert_reply stale_response_ref, :error, %{reason: "stale_generation"}

    stale_event_ref =
      push(old, "message", %{
        "type" => "job.event",
        "protocol_version" => 1,
        "remote_execution_id" => "00000000-0000-0000-0000-000000000099",
        "sequence" => 1,
        "event" => "spoofed"
      })

    assert_reply stale_event_ref, :error, %{reason: "stale_generation"}

    assert {:ok, agent} = AgentRegistry.find_agent(name)
    assert agent.channel_pid == current.channel_pid
    refute agent.info[:remote_timestamp] == "stale-heartbeat"
  end

  test "invalid heartbeat version cannot mutate a negotiated node" do
    name = "node-invalid-heartbeat"

    assert {:ok, _, joined} =
             socket(CommanderSocket, "invalid-heartbeat", %{name: name, commander_name: name})
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    negotiation_ref = push(joined, "message", negotiation())
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    heartbeat_ref =
      push(joined, "message", %{
        "type" => "heartbeat",
        "protocol_version" => 99,
        "timestamp" => "invalid-version",
        "capability_count" => 999
      })

    assert_reply heartbeat_ref, :error, %{reason: "unsupported_protocol_version"}
    assert {:ok, agent} = AgentRegistry.find_agent(name)
    refute agent.info[:remote_timestamp] == "invalid-version"
  end

  test "authenticated heartbeats retain only a strict TLS validity summary" do
    name = "node-live-tls-summary"
    Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander_updates")

    assert {:ok, _, joined} =
             socket(CommanderSocket, "live-tls-summary", %{name: name, commander_name: name})
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    negotiation_ref = push(joined, "message", negotiation())
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500
    assert_receive :commander_updates

    heartbeat_ref =
      push(joined, "message", %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "timestamp" => "2026-09-06T12:00:00Z",
        "capability_count" => 1,
        "tls" => %{
          "status" => "verified",
          "certificate_expires_at" => "2026-10-06T00:00:00Z"
        }
      })

    assert_reply heartbeat_ref, :ok, %{}, 500
    assert_receive :commander_updates

    assert {:ok, %{info: %{tls: tls}}} = AgentRegistry.find_agent(name)

    assert tls == %{
             "status" => "verified",
             "certificate_expires_at" => "2026-10-06T00:00:00Z"
           }

    secret = "CERTIFICATE-METADATA-SECRET-#{System.unique_integer([:positive])}"

    invalid_ref =
      push(joined, "message", %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "timestamp" => "2026-09-06T12:00:01Z",
        "capability_count" => 1,
        "tls" => Map.put(tls, "subject", secret)
      })

    assert_reply invalid_ref, :error, %{reason: "invalid_tls_summary"}, 500
    assert {:ok, %{info: %{tls: ^tls}}} = AgentRegistry.find_agent(name)
    refute inspect(tls) =~ secret

    unchanged_ref =
      push(joined, "message", %{
        "type" => "heartbeat",
        "protocol_version" => 1,
        "timestamp" => "2026-09-06T12:00:02Z",
        "capability_count" => 1,
        "tls" => tls
      })

    assert_reply unchanged_ref, :ok, %{}, 500
    refute_receive :commander_updates, 50
  end

  test "PTY negotiation preserves the legacy shell capability metadata" do
    name = "node-pty-metadata"

    assert {:ok, _, joined} =
             socket(CommanderSocket, "pty-metadata", %{name: name, commander_name: name})
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    ref = push(joined, "message", negotiation([pty_descriptor()]))
    assert_reply ref, :ok, %{capabilities: 1}, 500
    assert {:ok, %{info: info}} = AgentRegistry.find_agent(name)
    assert info.capabilities == [:shell]
    assert [%{id: "pty.shell"}] = info.capability_descriptors
  end

  test "registers a capability snapshot on the control channel" do
    socket =
      socket(CommanderSocket, "commander-node-capability", %{
        name: "node-capability",
        commander_name: "node-capability"
      })

    assert {:ok, _reply, joined} =
             subscribe_and_join(socket, CommanderChannel, "commander:node-capability")

    ref = push(joined, "message", negotiation())
    assert_reply ref, :ok, %{capabilities: 1}, 500

    assert {:ok, %{info: %{capability_descriptors: [descriptor]}}} =
             AgentRegistry.find_agent("node-capability")

    assert descriptor.id == "browser.control"
    assert descriptor.version == 1
  end

  test "runtime capability updates add and remove central descriptors without renegotiation" do
    name = "node-runtime-capabilities"

    assert {:ok, _, joined} =
             socket(CommanderSocket, "runtime-capabilities", %{name: name, commander_name: name})
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    negotiation_ref = push(joined, "message", negotiation([pty_descriptor()]))
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    add_ref =
      push(joined, "message", capability_update([pty_descriptor(), browser_descriptor()]))

    assert_reply add_ref, :ok, %{capabilities: 2}, 500
    assert {:ok, %{info: %{capability_descriptors: added}}} = AgentRegistry.find_agent(name)
    assert Enum.map(added, & &1.id) |> Enum.sort() == ["browser.control", "pty.shell"]

    remove_ref = push(joined, "message", capability_update([pty_descriptor()]))
    assert_reply remove_ref, :ok, %{capabilities: 1}, 500

    assert {:ok, %{info: info}} = AgentRegistry.find_agent(name)
    assert Enum.map(info.capability_descriptors, & &1.id) == ["pty.shell"]
    assert info.capabilities == [:shell]
  end

  test "a stale control generation cannot update central capabilities" do
    name = "node-stale-capabilities"
    assigns = %{name: name, commander_name: name}

    assert {:ok, _, old} =
             socket(CommanderSocket, "old-runtime-capabilities", assigns)
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    old_ref = push(old, "message", negotiation([pty_descriptor()]))
    assert_reply old_ref, :ok, %{capabilities: 1}, 500

    assert {:ok, _, current} =
             socket(CommanderSocket, "current-runtime-capabilities", assigns)
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    current_ref = push(current, "message", negotiation([pty_descriptor()]))
    assert_reply current_ref, :ok, %{capabilities: 1}, 500

    stale_ref = push(old, "message", capability_update([browser_descriptor()]))
    assert_reply stale_ref, :error, %{reason: "stale_generation"}, 500

    assert {:ok, %{info: info, channel_pid: channel_pid}} = AgentRegistry.find_agent(name)
    assert channel_pid == current.channel_pid
    assert Enum.map(info.capability_descriptors, & &1.id) == ["pty.shell"]
  end

  test "terminal agent errors log only normalized code and message size" do
    name = "node-safe-terminal-error"

    commander_socket =
      socket(CommanderSocket, "safe-terminal", %{name: name, commander_name: name})

    assert {:ok, _, control} =
             subscribe_and_join(commander_socket, CommanderChannel, "commander:#{name}")

    negotiation_ref = push(control, "message", negotiation([pty_descriptor()]))
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    assert {:ok, _, terminal} =
             subscribe_and_join(commander_socket, TerminalChannel, "terminal:#{name}")

    secret = "PTY-AGENT-ERROR-SECRET-#{System.unique_integer([:positive])}"
    secret_code = "ERROR-CODE-#{secret}"
    session_id = "session-safe"
    session_hash = :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    handler_id = "terminal-agent-error-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        push(terminal, "message", %{
          "type" => "error",
          "session_id" => session_id,
          "error_code" => secret_code,
          "message" => secret
        })

        assert_receive {:terminal_log,
                        %{
                          message: "Agent reported error",
                          error_code: "unknown_agent_error",
                          message_size: message_size,
                          session_id_hash: ^session_hash,
                          session_id_size: session_id_size
                        } = metadata},
                       500

        assert message_size == byte_size(secret)
        assert session_id_size == byte_size(session_id)
        refute Map.has_key?(metadata, :agent_message)
        refute inspect(metadata) =~ secret
      end)

    refute log =~ secret
    refute log =~ secret_code
  end

  test "unmatched control events log only a normalized code and safe sizes" do
    name = "node-safe-unmatched-event"

    assert {:ok, _, joined} =
             socket(CommanderSocket, "safe-unmatched-event", %{
               name: name,
               commander_name: name
             })
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    secret = "CONTROL-EVENT-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "control-unmatched-event-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:control_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        push(joined, secret, %{"body" => secret})

        assert_receive {:control_log,
                        %{
                          message: "Unmatched message in commander channel",
                          event_code: :unknown,
                          event_size: event_size,
                          payload_size: payload_size
                        } = metadata},
                       500

        assert event_size == byte_size(secret)
        assert payload_size > 0
        refute inspect(metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "ping and broadcast telemetry exclude remote time and event contents" do
    name = "node-safe-ping-broadcast"

    assert {:ok, _, joined} =
             socket(CommanderSocket, "safe-ping-broadcast", %{
               name: name,
               commander_name: name
             })
             |> subscribe_and_join(CommanderChannel, "commander:#{name}")

    secret = "CHANNEL-TELEMETRY-SECRET-#{System.unique_integer([:positive])}"
    handler_id = "control-ping-broadcast-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:control_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log([level: :debug], fn ->
        ping_ref = push(joined, "ping", %{"message" => "ping", "time" => secret})
        assert_reply ping_ref, :ok

        assert_receive {:control_log,
                        %{
                          message: "Ping received in commander channel",
                          message_type: "ping",
                          client_time_size: client_time_size
                        } = ping_metadata},
                       500

        assert client_time_size == byte_size(secret)
        refute inspect(ping_metadata) =~ secret

        broadcast = %Phoenix.Socket.Broadcast{
          topic: "commander:#{name}",
          event: secret,
          payload: %{"body" => secret}
        }

        assert {:noreply, ^joined} = CommanderChannel.handle_info(broadcast, joined)

        assert_receive {:control_log,
                        %{
                          message: "Broadcast received in commander channel",
                          event_code: :unknown,
                          event_size: event_size,
                          payload_size: payload_size
                        } = broadcast_metadata},
                       500

        assert event_size == byte_size(secret)
        assert payload_size > 0
        refute inspect(broadcast_metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "legacy commands and close events log fixed codes with hashed session correlation" do
    name = "node-safe-legacy-close"

    commander_socket =
      socket(CommanderSocket, "safe-legacy-close", %{name: name, commander_name: name})

    assert {:ok, _, control} =
             subscribe_and_join(commander_socket, CommanderChannel, "commander:#{name}")

    negotiation_ref = push(control, "message", negotiation([pty_descriptor()]))
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    assert {:ok, _, terminal} =
             subscribe_and_join(commander_socket, TerminalChannel, "terminal:#{name}")

    secret = "TERMINAL-CLOSE-SECRET-#{System.unique_integer([:positive])}"
    session_id = "#{secret}-session"
    expected_hash = :crypto.hash(:sha256, session_id) |> Base.encode16(case: :lower)
    handler_id = "terminal-legacy-close-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:gsmlg, :log],
      fn _event, _measurements, metadata, pid -> send(pid, {:terminal_log, metadata}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    log =
      capture_log(fn ->
        push(terminal, "command", %{"type" => secret, "body" => secret})

        assert_receive {:terminal_log,
                        %{
                          message: "Dispatching command to agent",
                          command_code: :unknown,
                          payload_size: command_payload_size
                        } = command_metadata},
                       500

        assert command_payload_size > 0
        refute inspect(command_metadata) =~ secret

        push(terminal, "message", %{
          "type" => "pty_closed",
          "session_id" => session_id,
          "exit_code" => secret,
          "reason" => secret
        })

        assert_receive {:terminal_log,
                        %{
                          message: "PTY session closed",
                          exit_code: :unknown,
                          session_id_hash: ^expected_hash,
                          session_id_size: session_id_size
                        } = close_metadata},
                       500

        assert session_id_size == byte_size(session_id)
        refute inspect(close_metadata) =~ secret
      end)

    refute log =~ secret
  end

  test "terminal topic is identity-bound and does not replace the live control connection" do
    commander_socket =
      socket(CommanderSocket, "control-node-pty", %{
        name: "node-pty",
        commander_name: "node-pty"
      })

    assert {:ok, _reply, control} =
             subscribe_and_join(commander_socket, CommanderChannel, "commander:node-pty")

    control_ref = push(control, "message", negotiation())
    assert_reply control_ref, :ok, %{capabilities: 1}, 500

    mismatched_socket =
      socket(CommanderSocket, "terminal-node-pty", %{
        name: "node-pty",
        commander_name: "node-pty"
      })

    assert {:error, %{reason: "identity_mismatch"}} =
             subscribe_and_join(mismatched_socket, TerminalChannel, "terminal:other-node")

    assert {:ok, _reply, _terminal} =
             subscribe_and_join(commander_socket, TerminalChannel, "terminal:node-pty")

    assert {:ok, %{channel_pid: channel_pid}} = AgentRegistry.find_agent("node-pty")
    assert channel_pid == control.channel_pid
  end

  test "PTY commands route only to the terminal channel on the negotiated socket" do
    name = "node-pty-routing"
    connection_id = make_ref()

    commander_socket =
      socket(CommanderSocket, "pty-routing", %{
        name: name,
        commander_name: name,
        connection_id: connection_id
      })

    assert {:ok, _, control} =
             subscribe_and_join(commander_socket, CommanderChannel, "commander:#{name}")

    negotiation_ref = push(control, "message", negotiation([pty_descriptor()]))
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    assert {:error, :terminal_not_connected} = CommandDispatcher.list_agent_sessions(name)
    assert Process.alive?(control.channel_pid)

    assert {:ok, _, terminal} =
             subscribe_and_join(commander_socket, TerminalChannel, "terminal:#{name}")

    assert :ok = CommandDispatcher.list_agent_sessions(name)
    assert_push "message", %{type: "list_sessions"}
    assert Process.alive?(control.channel_pid)
    assert Process.alive?(terminal.channel_pid)
  end

  test "control replacement fences the old terminal until the replacement socket attaches" do
    name = "node-pty-replacement"

    old_socket =
      socket(CommanderSocket, "pty-replacement-old", %{
        name: name,
        commander_name: name,
        connection_id: make_ref()
      })

    assert {:ok, _, old_control} =
             subscribe_and_join(old_socket, CommanderChannel, "commander:#{name}")

    old_negotiation = push(old_control, "message", negotiation([pty_descriptor()]))
    assert_reply old_negotiation, :ok, %{capabilities: 1}, 500

    assert {:ok, _, old_terminal} =
             subscribe_and_join(old_socket, TerminalChannel, "terminal:#{name}")

    concurrent_socket =
      socket(CommanderSocket, "pty-replacement-concurrent", %{
        name: name,
        commander_name: name,
        connection_id: make_ref()
      })

    assert {:error, %{reason: "control_connection_mismatch"}} =
             subscribe_and_join(concurrent_socket, TerminalChannel, "terminal:#{name}")

    replacement_socket =
      socket(CommanderSocket, "pty-replacement-current", %{
        name: name,
        commander_name: name,
        connection_id: make_ref()
      })

    assert {:ok, _, replacement_control} =
             subscribe_and_join(replacement_socket, CommanderChannel, "commander:#{name}")

    replacement_negotiation =
      push(replacement_control, "message", negotiation([pty_descriptor()]))

    assert_reply replacement_negotiation, :ok, %{capabilities: 1}, 500

    assert {:error, :terminal_not_connected} = CommandDispatcher.list_agent_sessions(name)

    stale_ref = push(old_terminal, "message", %{"type" => "sessions_list", "sessions" => []})
    assert_reply stale_ref, :error, %{reason: "stale_generation"}, 500

    assert {:ok, _, replacement_terminal} =
             subscribe_and_join(replacement_socket, TerminalChannel, "terminal:#{name}")

    assert :ok = CommandDispatcher.list_agent_sessions(name)
    assert_push "message", %{type: "list_sessions"}
    assert Process.alive?(old_terminal.channel_pid)
    assert Process.alive?(replacement_terminal.channel_pid)
  end

  test "rejects a response that is not owned by the authenticated node without crashing" do
    socket =
      socket(CommanderSocket, "commander-node-response", %{
        name: "node-response",
        commander_name: "node-response"
      })

    assert {:ok, _reply, joined} =
             subscribe_and_join(socket, CommanderChannel, "commander:node-response")

    negotiation_ref = push(joined, "message", negotiation())
    assert_reply negotiation_ref, :ok, %{capabilities: 1}, 500

    ref =
      push(joined, "message", %{
        "type" => "rpc.response",
        "protocol_version" => 1,
        "request_id" => "00000000-0000-0000-0000-000000000071",
        "result" => %{}
      })

    assert_reply ref, :error, %{reason: "unknown_request"}
    assert Process.alive?(joined.channel_pid)
  end

  defp negotiation(capabilities \\ [browser_descriptor()]) do
    %{
      "type" => "version.negotiation",
      "protocol_version" => 1,
      "capabilities" => capabilities
    }
  end

  defp capability_update(capabilities) do
    %{
      "type" => "capabilities.update",
      "protocol_version" => 1,
      "capabilities" => capabilities
    }
  end

  defp browser_descriptor do
    %{
      "id" => "browser.control",
      "version" => 1,
      "backend" => "cloakbrowser",
      "operations" => ["manager.status"],
      "limits" => %{"max_sessions" => 1},
      "workflows" => []
    }
  end

  defp pty_descriptor do
    %{
      "id" => "pty.shell",
      "version" => 1,
      "backend" => "native",
      "operations" => [],
      "limits" => %{},
      "workflows" => []
    }
  end
end
