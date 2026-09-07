defmodule GSMLG.Commander.Protocol.EnvelopeTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.Protocol.Envelope

  @request_id "123e4567-e89b-12d3-a456-426614174000"
  @remote_execution_id "223e4567-e89b-12d3-a456-426614174000"
  @job_id "323e4567-e89b-42d3-a456-426614174000"
  @now ~U[2026-09-04 12:00:00Z]

  test "publishes the supported protocol and browser capability versions" do
    assert Envelope.protocol_version() == 1
    assert Envelope.browser_control_version() == 1

    assert Envelope.browser_control_operations() == [
             "manager.status",
             "profiles.list",
             "profile.status",
             "profile.launch",
             "profile.stop",
             "session.open",
             "session.observe",
             "session.act",
             "session.manual_acquire",
             "session.manual_release",
             "session.close",
             "workflow.start",
             "workflow.status",
             "workflow.cancel",
             "workflow.resume",
             "workflow.reconcile",
             "artifact.fetch_inline",
             "artifact.upload",
             "artifact.ack"
           ]
  end

  test "round-trips version negotiation with capability descriptors" do
    wire = %{
      "type" => "version.negotiation",
      "protocol_version" => 1,
      "capabilities" => [capability_wire()]
    }

    assert {:ok, envelope} = Envelope.decode(wire)
    assert envelope.__struct__ == GSMLG.Commander.Protocol.VersionNegotiation
    assert [capability] = envelope.capabilities
    assert capability.__struct__ == GSMLG.Commander.Protocol.Capability
    assert capability.id == "browser.control"
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  test "round-trips a runtime capability update separately from initial negotiation" do
    wire = %{
      "type" => "capabilities.update",
      "protocol_version" => 1,
      "capabilities" => [capability_wire()]
    }

    assert {:ok, envelope} = Envelope.decode(wire)
    assert envelope.__struct__ == GSMLG.Commander.Protocol.CapabilitiesUpdate
    assert [capability] = envelope.capabilities
    assert capability.id == "browser.control"
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  test "round-trips the built-in PTY descriptor without making PTY an RPC data path" do
    wire = %{
      "type" => "capability.descriptor",
      "protocol_version" => 1,
      "id" => "pty.shell",
      "version" => 1,
      "backend" => "native",
      "operations" => [],
      "limits" => %{},
      "workflows" => []
    }

    assert {:ok, capability} = Envelope.decode(wire)
    assert capability.id == "pty.shell"
    assert capability.operations == []
    assert {:ok, ^wire} = Envelope.encode(capability)
  end

  test "round-trips a standalone capability descriptor" do
    wire =
      Map.merge(capability_wire(), %{"type" => "capability.descriptor", "protocol_version" => 1})

    assert {:ok, envelope} = Envelope.decode(wire)
    assert envelope.__struct__ == GSMLG.Commander.Protocol.Capability
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  test "round-trips an rpc request with its required idempotency key" do
    wire = request_wire()

    assert {:ok, envelope} = Envelope.decode(wire, now: @now)
    assert envelope.__struct__ == GSMLG.Commander.Protocol.RPCRequest
    assert envelope.request_id == @request_id
    assert envelope.idempotency_key == "launch-profile-7"
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  test "encoding a previously validated request is independent of the encoder clock" do
    wire = Map.put(request_wire(), "deadline_at", "2020-01-01T00:01:00Z")

    assert {:ok, envelope} = Envelope.decode(wire, now: ~U[2020-01-01 00:00:00Z])
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  test "round-trips rpc accepted" do
    assert_round_trip(
      %{
        "type" => "rpc.accepted",
        "protocol_version" => 1,
        "request_id" => @request_id,
        "remote_execution_id" => @remote_execution_id
      },
      GSMLG.Commander.Protocol.RPCAccepted
    )
  end

  test "round-trips terminal rpc response" do
    assert_round_trip(
      %{
        "type" => "rpc.response",
        "protocol_version" => 1,
        "request_id" => @request_id,
        "result" => %{"status" => "running"}
      },
      GSMLG.Commander.Protocol.RPCResponse
    )
  end

  test "round-trips terminal rpc error" do
    assert_round_trip(
      %{
        "type" => "rpc.error",
        "protocol_version" => 1,
        "request_id" => @request_id,
        "class" => "browser",
        "code" => "profile_not_found",
        "message" => "The requested profile does not exist",
        "retryable" => false,
        "human_action" => "Choose an existing profile",
        "details" => %{"profile_id" => "missing"}
      },
      GSMLG.Commander.Protocol.RPCError
    )
  end

  test "round-trips a job event with optional fields" do
    assert_round_trip(
      %{
        "type" => "job.event",
        "protocol_version" => 1,
        "remote_execution_id" => @remote_execution_id,
        "sequence" => 1,
        "event" => "workflow.phase_changed",
        "phase" => "launch",
        "metadata" => %{"central_job_id" => @job_id, "status" => "running"},
        "occurred_at" => "2026-09-04T12:00:01Z"
      },
      GSMLG.Commander.Protocol.JobEvent
    )
  end

  test "workflow events require bounded central-job correlation metadata" do
    base = %{
      "type" => "job.event",
      "protocol_version" => 1,
      "remote_execution_id" => @remote_execution_id,
      "sequence" => 2,
      "event" => "workflow.completed"
    }

    assert {:error, %{code: "invalid_event_metadata"}} = Envelope.decode(base)

    assert {:error, %{code: "invalid_uuid"}} =
             Envelope.decode(Map.put(base, "metadata", %{"central_job_id" => "central-job-1"}))

    assert {:error, %{code: "unknown_event_metadata"}} =
             Envelope.decode(
               Map.put(base, "metadata", %{"central_job_id" => @job_id, "prompt" => "secret"})
             )
  end

  test "round-trips a cumulative event ack including sequence zero" do
    assert_round_trip(
      %{
        "type" => "event.ack",
        "protocol_version" => 1,
        "remote_execution_id" => @remote_execution_id,
        "highest_contiguous_sequence" => 0
      },
      GSMLG.Commander.Protocol.EventAck
    )
  end

  test "encoding is deterministic at the public map level" do
    assert {:ok, envelope} = Envelope.decode(request_wire(), now: @now)
    assert {:ok, first} = Envelope.encode(envelope)
    assert {:ok, second} = Envelope.encode(envelope)
    assert first == second
  end

  defp assert_round_trip(wire, expected_module) do
    assert {:ok, envelope} = Envelope.decode(wire)
    assert envelope.__struct__ == expected_module
    assert {:ok, ^wire} = Envelope.encode(envelope)
  end

  defp request_wire do
    %{
      "type" => "rpc.request",
      "protocol_version" => 1,
      "request_id" => @request_id,
      "capability" => "browser.control",
      "capability_version" => 1,
      "operation" => "profile.launch",
      "idempotency_key" => "launch-profile-7",
      "deadline_at" => "2026-09-04T12:01:00Z",
      "payload" => %{"profile_id" => "profile-7"}
    }
  end

  defp capability_wire do
    %{
      "id" => "browser.control",
      "version" => 1,
      "backend" => "chromium",
      "operations" => ["manager.status", "profile.launch", "session.observe"],
      "limits" => %{"max_sessions" => 4, "max_jobs" => 0},
      "workflows" => ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
    }
  end
end
