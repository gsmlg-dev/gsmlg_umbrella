defmodule GSMLG.Browser.CommanderBridgeTest do
  use ExUnit.Case, async: true

  alias GSMLG.Browser.{Artifact, CommanderBridge, Job, Node, Profile, Session, WorkflowContract}
  alias GSMLG.Commander.Protocol.{RPCAccepted, RPCResponse}

  test "workflow start binds the durable authenticated actor identity" do
    actor_id = Ecto.UUID.generate()
    job_id = Ecto.UUID.generate()
    remote_execution_id = Ecto.UUID.generate()

    job = %Job{
      id: job_id,
      idempotency_key: "job-once",
      deadline_at: ~U[2026-09-06 01:00:00Z],
      workflow: "gemini.deep_research",
      workflow_version: 1,
      input: %{
        "prompt" => "Research BEAM",
        "output_locale" => "en-US",
        "research_scope" => "primary sources",
        "required_sections" => ["Summary"],
        "auto_approve_plan" => true
      },
      output_formats: ["report.markdown", "report.json", "sources.json"],
      requested_by_actor_id: actor_id
    }

    node = %Node{}
    profile = %Profile{external_id: "profile-1"}

    dispatch = fn request ->
      send(self(), {:workflow_start_request, request})

      {:ok,
       %RPCAccepted{
         protocol_version: 1,
         request_id: request.request_id,
         remote_execution_id: remote_execution_id
       }}
    end

    assert {:ok, %RPCAccepted{remote_execution_id: ^remote_execution_id}} =
             CommanderBridge.start(job, node, profile, dispatch: dispatch)

    assert_received {:workflow_start_request, request}
    assert request.payload["central_job_id"] == job_id
    assert request.payload["requested_by_actor_id"] == actor_id
  end

  test "central workflow contract rejects nested identity overrides" do
    input = %{
      "prompt" => "Research BEAM",
      "output_locale" => "en-US",
      "research_scope" => "primary sources",
      "required_sections" => ["Summary"],
      "auto_approve_plan" => true
    }

    outputs = ["report.markdown", "report.json", "sources.json"]

    assert :ok = WorkflowContract.validate("gemini.deep_research", 1, input, outputs)

    assert {:error, :invalid_workflow_input} =
             WorkflowContract.validate(
               "gemini.deep_research",
               1,
               Map.put(input, "profile_id", "untrusted-profile"),
               outputs
             )

    assert {:error, :invalid_workflow_input} =
             WorkflowContract.validate(
               "gemini.deep_research",
               1,
               Map.put(input, "requested_by_actor_id", "untrusted-actor"),
               outputs
             )
  end

  test "session artifact ACK is bound to both durable and remote session identities" do
    session = %Session{id: Ecto.UUID.generate(), remote_session_id: Ecto.UUID.generate()}
    artifact = %Artifact{id: Ecto.UUID.generate(), sha256: String.duplicate("a", 64)}
    node = %Node{}

    dispatch = fn request ->
      send(self(), {:artifact_ack_request, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: Map.put(request.payload, "status", "acked") |> Map.delete("status")
       }}
    end

    assert {:ok, result} =
             CommanderBridge.artifact_ack(session, node, artifact, dispatch: dispatch)

    assert_received {:artifact_ack_request, request}

    assert request.payload == %{
             "central_session_id" => session.id,
             "remote_session_id" => session.remote_session_id,
             "artifact_id" => artifact.id,
             "sha256" => artifact.sha256
           }

    assert result == request.payload
  end
end
