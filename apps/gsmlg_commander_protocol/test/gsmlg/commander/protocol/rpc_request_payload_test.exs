defmodule GSMLG.Commander.Protocol.RPCRequestPayloadTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.Protocol.{Constants, Envelope, Error}

  @now ~U[2026-09-04 12:00:00Z]
  @request_id "123e4567-e89b-42d3-a456-426614174000"
  @job_id "323e4567-e89b-42d3-a456-426614174000"
  @execution_id "223e4567-e89b-42d3-a456-426614174000"
  @artifact_id "423e4567-e89b-42d3-a456-426614174000"
  @sha256 String.duplicate("a", 64)

  test "every browser.control/v1 operation accepts only its canonical payload" do
    assert Enum.sort(Enum.map(payloads(), &elem(&1, 0))) ==
             Enum.sort(Constants.browser_control_operations())

    for {operation, payload} <- payloads() do
      assert {:ok, request} = Envelope.decode(request(operation, payload), now: @now)
      assert request.operation == operation
      assert request.payload == payload

      assert {:error, %Error{code: "unknown_fields"}} =
               Envelope.decode(request(operation, Map.put(payload, "forbidden", true)), now: @now)
    end
  end

  test "workflow operations enforce UUID identity, base workflow/version, input, and outputs" do
    start = payload("workflow.start")

    for invalid <- [
          %{start | "central_job_id" => "central-job-1"},
          %{start | "workflow" => "gemini.deep_research/v1"},
          %{start | "workflow_version" => 2},
          %{start | "output_formats" => ["report.markdown", "report.json"]},
          put_in(start, ["input", "raw_cdp"], true),
          put_in(start, ["input", "output_locale"], "not_a_locale"),
          put_in(start, ["input", "required_sections"], ["Summary", "Summary"]),
          put_in(
            start,
            ["input", "required_sections"],
            Enum.map(1..33, &"Section #{&1}")
          ),
          put_in(start, ["input", "required_sections"], [String.duplicate("x", 129)])
        ] do
      assert_invalid("workflow.start", invalid)
    end

    for operation <- ~w(workflow.status workflow.cancel workflow.resume) do
      assert_invalid(operation, %{payload(operation) | "central_job_id" => "not-a-uuid"})
      assert_invalid(operation, %{payload(operation) | "remote_execution_id" => "not-a-uuid"})
    end

    assert {:ok, _request} =
             Envelope.decode(
               request("workflow.reconcile", %{"central_job_id" => @job_id}),
               now: @now
             )

    assert_invalid("workflow.resume", %{payload("workflow.resume") | "operator_id" => ""})
  end

  test "session action schema rejects raw operations, mismatched sessions, and unsafe locators" do
    action_payload = payload("session.act")

    navigate =
      put_in(action_payload, ["action"], %{
        "action_id" => "action-nav",
        "session_id" => "remote-session-1",
        "expected_revision" => 4,
        "type" => "navigate",
        "url" => "https://gemini.google.com/app#conversation",
        "timeout_ms" => 5_000
      })

    assert {:ok, _request} = Envelope.decode(request("session.act", navigate), now: @now)

    assert_invalid(
      "session.act",
      put_in(action_payload, ["action"], %{
        "action_id" => "action-1",
        "session_id" => "remote-session-1",
        "expected_revision" => 4,
        "type" => "raw_cdp",
        "method" => "Runtime.evaluate",
        "timeout_ms" => 5_000
      })
    )

    assert_invalid(
      "session.act",
      put_in(action_payload, ["action", "session_id"], "other-session")
    )

    assert_invalid(
      "session.act",
      put_in(action_payload, ["action", "locator"], %{
        "attribute" => %{"name" => "data-testid", "value" => "submit"}
      })
    )
  end

  test "session open and manual controls are closed and bounded" do
    open = payload("session.open")

    manual_open =
      open
      |> Map.put("mode", "manual")
      |> Map.put("operator_id", "operator-1")

    assert {:ok, _request} =
             Envelope.decode(request("session.open", manual_open), now: @now)

    assert_invalid("session.open", Map.delete(manual_open, "operator_id"))
    assert_invalid("session.open", %{manual_open | "operator_id" => ""})
    assert_invalid("session.open", Map.put(open, "operator_id", "operator-1"))

    for invalid <- [
          %{open | "central_session_id" => "not-a-uuid"},
          %{open | "mode" => "shared"},
          %{open | "authorized_origins" => ["http://gemini.google.com"]},
          %{open | "ttl_ms" => 86_400_001},
          %{open | "permissions" => %{"cookies" => true}}
        ] do
      assert_invalid("session.open", invalid)
    end

    assert_invalid(
      "session.manual_acquire",
      %{payload("session.manual_acquire") | "operator_id" => ""}
    )

    assert_invalid(
      "session.manual_release",
      %{payload("session.manual_release") | "lease_id" => ""}
    )
  end

  test "artifact operations require UUID ownership, integrity, and exact signed-upload headers" do
    for operation <- ~w(artifact.fetch_inline artifact.upload artifact.ack) do
      assert_invalid(operation, %{payload(operation) | "central_job_id" => "central-job-1"})
      assert_invalid(operation, %{payload(operation) | "artifact_id" => "artifact-1"})
    end

    upload = payload("artifact.upload")

    for invalid <- [
          %{upload | "upload_url" => "http://uploads.example.test/object"},
          %{upload | "upload_url" => "https://uploads.example.test/object?token=secret"},
          put_in(upload, ["required_headers", "content-length"], String.duplicate("9", 21)),
          put_in(upload, ["required_headers", "x-browser-upload-token"], "bad\r\nheader"),
          update_in(upload, ["required_headers"], &Map.put(&1, "authorization", "secret"))
        ] do
      assert_invalid("artifact.upload", invalid)
    end

    assert_invalid("artifact.ack", %{payload("artifact.ack") | "sha256" => "bad"})

    for operation <- ~w(artifact.fetch_inline artifact.upload artifact.ack) do
      session_payload =
        payload(operation)
        |> Map.drop(~w(central_job_id remote_execution_id))
        |> Map.merge(%{
          "central_session_id" => "523e4567-e89b-42d3-a456-426614174000",
          "remote_session_id" => "623e4567-e89b-42d3-a456-426614174000"
        })

      assert {:ok, _request} = Envelope.decode(request(operation, session_payload), now: @now)
      assert_invalid(operation, Map.put(session_payload, "central_job_id", @job_id))
      assert_invalid(operation, %{session_payload | "central_session_id" => "not-a-uuid"})
    end
  end

  test "encoding revalidates an operation payload instead of trusting the struct" do
    assert {:ok, decoded} =
             Envelope.decode(request("profile.launch", payload("profile.launch")), now: @now)

    invalid = %{decoded | payload: %{"profile_id" => "profile-1", "raw_cdp" => true}}
    assert {:error, %Error{code: "unknown_fields"}} = Envelope.encode(invalid)
  end

  test "every nonempty operation rejects deletion of each required field" do
    optional_fields = %{
      "session.open" => ["permissions"],
      "workflow.reconcile" => ["remote_execution_id"]
    }

    for {operation, payload} <- payloads(),
        field <- Map.keys(payload) -- Map.get(optional_fields, operation, []) do
      assert_invalid(operation, Map.delete(payload, field))
    end
  end

  defp payloads do
    [
      {"manager.status", %{}},
      {"profiles.list", %{}},
      {"profile.status", %{"profile_id" => "profile-1"}},
      {"profile.launch", %{"profile_id" => "profile-1"}},
      {"profile.stop", %{"profile_id" => "profile-1"}},
      {"session.open",
       %{
         "central_session_id" => "523e4567-e89b-42d3-a456-426614174000",
         "profile_id" => "profile-1",
         "mode" => "automation",
         "authorized_origins" => ["https://gemini.google.com"],
         "ttl_ms" => 60_000,
         "permissions" => %{"screenshot" => true, "download" => false}
       }},
      {"session.observe", %{"session_id" => "remote-session-1"}},
      {"session.act",
       %{
         "session_id" => "remote-session-1",
         "action" => %{
           "action_id" => "action-1",
           "session_id" => "remote-session-1",
           "expected_revision" => 4,
           "type" => "click",
           "locator" => %{"role" => "button", "accessible_name" => "Send"},
           "timeout_ms" => 5_000,
           "preconditions" => [],
           "postconditions" => []
         }
       }},
      {"session.manual_acquire",
       %{"session_id" => "remote-session-1", "operator_id" => "operator-1"}},
      {"session.manual_release",
       %{
         "session_id" => "remote-session-1",
         "lease_id" => "lease-1",
         "operator_id" => "operator-1"
       }},
      {"session.close", %{"session_id" => "remote-session-1"}},
      {"workflow.start",
       %{
         "central_job_id" => @job_id,
         "workflow" => "gemini.deep_research",
         "workflow_version" => 1,
         "profile_id" => "profile-1",
         "input" => %{
           "prompt" => "Research a bounded topic",
           "output_locale" => "en-US",
           "research_scope" => "web",
           "required_sections" => ["Summary", "Evidence"],
           "auto_approve_plan" => true
         },
         "output_formats" => ["report.markdown", "report.json", "sources.json"],
         "requested_by_actor_id" => "operator-1"
       }},
      {"workflow.status", %{"central_job_id" => @job_id, "remote_execution_id" => @execution_id}},
      {"workflow.cancel", %{"central_job_id" => @job_id, "remote_execution_id" => @execution_id}},
      {"workflow.resume",
       %{
         "central_job_id" => @job_id,
         "remote_execution_id" => @execution_id,
         "operator_id" => "operator-1"
       }},
      {"workflow.reconcile", %{"central_job_id" => @job_id}},
      {"artifact.fetch_inline",
       %{
         "artifact_id" => @artifact_id,
         "central_job_id" => @job_id,
         "remote_execution_id" => @execution_id
       }},
      {"artifact.upload",
       %{
         "artifact_id" => @artifact_id,
         "central_job_id" => @job_id,
         "remote_execution_id" => @execution_id,
         "upload_url" => "https://uploads.example.test/browser-artifacts/object",
         "required_headers" => %{
           "content-type" => "application/json",
           "content-length" => "4",
           "x-content-sha256" => @sha256,
           "x-browser-upload-token" => "one-use-token"
         }
       }},
      {"artifact.ack",
       %{
         "artifact_id" => @artifact_id,
         "central_job_id" => @job_id,
         "remote_execution_id" => @execution_id,
         "sha256" => @sha256
       }}
    ]
  end

  defp payload(operation), do: payloads() |> Map.new() |> Map.fetch!(operation)

  defp request(operation, payload) do
    %{
      "type" => "rpc.request",
      "protocol_version" => 1,
      "request_id" => @request_id,
      "capability" => "browser.control",
      "capability_version" => 1,
      "operation" => operation,
      "idempotency_key" => "payload-contract-#{operation}",
      "deadline_at" => "2026-09-04T12:01:00Z",
      "payload" => payload
    }
  end

  defp assert_invalid(operation, payload) do
    assert {:error, %Error{}} = Envelope.decode(request(operation, payload), now: @now)
  end
end
