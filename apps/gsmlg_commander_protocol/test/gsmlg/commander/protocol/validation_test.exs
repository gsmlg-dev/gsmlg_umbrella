defmodule GSMLG.Commander.Protocol.ValidationTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.Protocol.Envelope
  alias GSMLG.Commander.Protocol.Error

  @request_id "123e4567-e89b-12d3-a456-426614174000"
  @remote_execution_id "223e4567-e89b-12d3-a456-426614174000"
  @job_id "323e4567-e89b-42d3-a456-426614174000"
  @now ~U[2026-09-04 12:00:00Z]

  test "rejects non-maps and atom-key maps without atomizing input" do
    assert_error(Envelope.decode("rpc.request"), "invalid_envelope")
    assert_error(Envelope.decode(%{type: "rpc.request"}), "non_string_key")
  end

  test "rejects unknown and missing message types" do
    assert_error(Envelope.decode(%{"type" => "rpc.future"}), "unknown_message_type")
    assert_error(Envelope.decode(%{}), "missing_field")
  end

  test "rejects incompatible protocol versions for every envelope" do
    wire = Map.put(request_wire(), "protocol_version", 2)
    assert_error(Envelope.decode(wire, now: @now), "incompatible_protocol_version")
  end

  test "rejects unknown browser capability versions" do
    wire = Map.put(request_wire(), "capability_version", 2)
    assert_error(Envelope.decode(wire, now: @now), "unknown_capability_version")

    descriptor = Map.put(capability_envelope(), "version", 2)
    assert_error(Envelope.decode(descriptor), "unknown_capability_version")
  end

  test "rejects unknown and missing fields without echoing the complete payload" do
    extra = Map.put(request_wire(), "future", "secret-wire-value")

    assert {:error, %{__struct__: Error, code: "unknown_fields"} = error} =
             Envelope.decode(extra, now: @now)

    refute inspect(error) =~ "secret-wire-value"

    missing = Map.delete(request_wire(), "request_id")
    assert_error(Envelope.decode(missing, now: @now), "missing_field")
  end

  test "rejects an rpc request without an idempotency key" do
    wire = Map.delete(request_wire(), "idempotency_key")
    assert_error(Envelope.decode(wire, now: @now), "missing_field")
  end

  test "rejects malformed UUIDs for request and execution identifiers" do
    assert_error(
      Envelope.decode(Map.put(request_wire(), "request_id", "not-a-uuid"), now: @now),
      "invalid_uuid"
    )

    assert_error(
      Envelope.decode(%{
        "type" => "rpc.accepted",
        "protocol_version" => 1,
        "request_id" => @request_id,
        "remote_execution_id" => "not-a-uuid"
      }),
      "invalid_uuid"
    )

    assert_error(
      Envelope.decode(Map.put(request_wire(), "request_id", @request_id <> "\n"), now: @now),
      "invalid_uuid"
    )
  end

  test "rejects malformed and expired request deadlines using injected time" do
    malformed = Map.put(request_wire(), "deadline_at", "tomorrow")
    assert_error(Envelope.decode(malformed, now: @now), "invalid_timestamp")

    expired = Map.put(request_wire(), "deadline_at", "2026-09-04T12:00:00Z")
    assert_error(Envelope.decode(expired, now: fn -> @now end), "expired_deadline")
  end

  test "rejects a non-map request payload and recursively rejects atom map keys" do
    assert_error(
      Envelope.decode(Map.put(request_wire(), "payload", "profile-7"), now: @now),
      "invalid_map"
    )

    assert_error(
      Envelope.decode(Map.put(request_wire(), "payload", %{"nested" => %{secret: true}}),
        now: @now
      ),
      "non_string_key"
    )
  end

  test "rejects unknown operations and invalid idempotency keys" do
    assert_error(
      Envelope.decode(Map.put(request_wire(), "operation", "browser.explode"), now: @now),
      "unknown_operation"
    )

    assert_error(
      Envelope.decode(Map.put(request_wire(), "idempotency_key", ""), now: @now),
      "invalid_string"
    )
  end

  test "validates capability operation subsets, duplicates, limits, and workflows" do
    assert_error(
      Envelope.decode(Map.put(capability_envelope(), "operations", ["browser.explode"])),
      "unknown_operation"
    )

    assert_error(
      Envelope.decode(
        Map.put(capability_envelope(), "operations", ["manager.status", "manager.status"])
      ),
      "duplicate_value"
    )

    assert_error(
      Envelope.decode(Map.put(capability_envelope(), "limits", %{"max_sessions" => -1})),
      "invalid_nonnegative_integer"
    )

    assert_error(
      Envelope.decode(Map.put(capability_envelope(), "workflows", ["checkout"])),
      "invalid_versioned_string"
    )

    assert_error(
      Envelope.decode(Map.put(capability_envelope(), "workflows", ["checkout@1"])),
      "invalid_versioned_string"
    )

    assert_error(
      Envelope.decode(
        Map.put(capability_envelope(), "workflows", [
          "gemini.deep_research/v1",
          "gemini.deep_research/v1"
        ])
      ),
      "duplicate_value"
    )
  end

  test "accepts canonical slash-versioned workflow identifiers" do
    workflows = ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
    wire = Map.put(capability_envelope(), "workflows", workflows)

    assert {:ok, capability} = Envelope.decode(wire)
    assert capability.workflows == workflows
  end

  test "validates terminal response and error payload shapes" do
    response = %{
      "type" => "rpc.response",
      "protocol_version" => 1,
      "request_id" => @request_id,
      "result" => []
    }

    assert_error(Envelope.decode(response), "invalid_map")

    rpc_error = %{
      "type" => "rpc.error",
      "protocol_version" => 1,
      "request_id" => @request_id,
      "class" => "browser",
      "code" => "unavailable",
      "message" => "Browser unavailable",
      "retryable" => "yes",
      "human_action" => "Retry later",
      "details" => %{}
    }

    assert_error(Envelope.decode(rpc_error), "invalid_boolean")
  end

  test "validates event timestamps, positive job sequences, and nonnegative ack sequences" do
    event = %{
      "type" => "job.event",
      "protocol_version" => 1,
      "remote_execution_id" => @remote_execution_id,
      "sequence" => 0,
      "event" => "workflow.started",
      "metadata" => %{"central_job_id" => @job_id}
    }

    assert_error(Envelope.decode(event), "invalid_positive_integer")

    malformed_time = Map.merge(event, %{"sequence" => 1, "occurred_at" => "soon"})
    assert_error(Envelope.decode(malformed_time), "invalid_timestamp")

    ack = %{
      "type" => "event.ack",
      "protocol_version" => 1,
      "remote_execution_id" => @remote_execution_id,
      "highest_contiguous_sequence" => -1
    }

    assert_error(Envelope.decode(ack), "invalid_nonnegative_integer")
  end

  test "rejects decoded and encoded messages larger than 256 KiB" do
    oversized = Map.put(request_wire(), "payload", %{"blob" => String.duplicate("x", 262_144)})
    assert_error(Envelope.decode(oversized, now: @now), "message_too_large")

    assert {:ok, envelope} = Envelope.decode(request_wire(), now: @now)
    oversized_struct = %{envelope | payload: %{"blob" => String.duplicate("x", 262_144)}}
    assert_error(Envelope.encode(oversized_struct), "message_too_large")
  end

  test "encode validates structs rather than serializing invalid public data" do
    assert {:ok, envelope} = Envelope.decode(request_wire(), now: @now)
    invalid = %{envelope | payload: %{unsafe: "value"}}
    assert_error(Envelope.encode(invalid), "non_string_key")

    assert_error(Envelope.encode(%{}), "unsupported_struct")
  end

  test "encode returns typed data for an invalid nested capability" do
    negotiation = %{
      "type" => "version.negotiation",
      "protocol_version" => 1,
      "capabilities" => [Map.drop(capability_envelope(), ["type", "protocol_version"])]
    }

    assert {:ok, envelope} = Envelope.decode(negotiation)
    invalid = %{envelope | capabilities: [%{}]}
    assert_error(Envelope.encode(invalid), "invalid_capability_descriptor")
  end

  test "decode returns typed data for invalid UTF-8 binary values" do
    wire = Map.put(request_wire(), "idempotency_key", <<255>>)
    assert_error(Envelope.decode(wire, now: @now), "invalid_utf8")

    assert_error(Envelope.decode(%{<<255>> => "rpc.request"}), "invalid_utf8")
  end

  test "encode returns typed data for invalid UTF-8 binary values" do
    assert {:ok, request} = Envelope.decode(request_wire(), now: @now)
    invalid = %{request | idempotency_key: <<255>>}
    assert_error(Envelope.encode(invalid), "invalid_utf8")

    invalid_nested_key = %{request | payload: %{<<255>> => "value"}}
    assert_error(Envelope.encode(invalid_nested_key), "invalid_utf8")
  end

  test "decode returns typed data for a non-map nested capability" do
    negotiation = %{
      "type" => "version.negotiation",
      "protocol_version" => 1,
      "capabilities" => ["browser.control@1"]
    }

    assert_error(Envelope.decode(negotiation), "invalid_capability_descriptor")
  end

  defp assert_error({:error, %{__struct__: Error} = error}, code) do
    assert error.class in ["protocol", "validation", "size"]
    assert error.code == code
    assert is_map(error.details)
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

  defp capability_envelope do
    %{
      "type" => "capability.descriptor",
      "protocol_version" => 1,
      "id" => "browser.control",
      "version" => 1,
      "backend" => "chromium",
      "operations" => ["manager.status"],
      "limits" => %{"max_sessions" => 4},
      "workflows" => ["gemini.deep_research/v1"]
    }
  end
end
