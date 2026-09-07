defmodule GSMLG.Browser.TelemetryTest do
  use GSMLG.Browser.DataCase, async: false

  alias GSMLG.Browser
  alias GSMLG.Browser.{Artifact, ArtifactService}
  alias GSMLG.Commander.Protocol.{ArtifactManifest, RPCError, RPCResponse}

  @reconcile_event [:gsmlg, :browser, :reconcile, :complete]
  @artifact_event [:gsmlg, :browser, :artifact, :transfer]

  setup do
    handler_id = "browser-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [@reconcile_event, @artifact_event],
        fn event, measurements, metadata, pid ->
          send(pid, {:browser_telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    remote_id = Ecto.UUID.generate()
    job = job_fixture(actor, node, profile, %{status: "running", remote_execution_id: remote_id})

    %{job: job, node: node, remote_id: remote_id}
  end

  test "reconcile emits duration and an allowlisted successful outcome", ctx do
    dispatch = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: reconcile_result(ctx)
       }}
    end

    assert {:ok, _job} = Browser.reconcile_job_id(ctx.job.id, dispatch: dispatch)

    assert_receive {:browser_telemetry, @reconcile_event, measurements, metadata}
    assert is_integer(measurements.duration)
    assert measurements.duration >= 0
    assert measurements.count == 1

    assert metadata == %{
             job_id: ctx.job.id,
             outcome: "ok",
             failure_code: nil
           }
  end

  test "reconcile emits only a stable failure code and never the remote reason", ctx do
    secret = "prompt-body-and-token-must-not-leak"

    assert {:error, {:transport_failed, ^secret}} =
             Browser.reconcile_job_id(ctx.job.id,
               dispatch: fn _request -> {:error, {:transport_failed, secret}} end
             )

    assert_receive {:browser_telemetry, @reconcile_event, measurements, metadata}
    assert measurements.count == 1

    assert metadata == %{
             job_id: ctx.job.id,
             outcome: "error",
             failure_code: "operation_failed"
           }

    refute inspect({measurements, metadata}) =~ secret
  end

  test "reconcile preserves an allowlisted remote failure code without remote details", ctx do
    secret = "remote-error-details-must-not-leak"

    rpc_error = %RPCError{
      protocol_version: 1,
      request_id: Ecto.UUID.generate(),
      class: "availability",
      code: "node_offline",
      message: secret,
      retryable: true,
      human_action: "retry",
      details: %{"secret" => secret}
    }

    assert {:error, ^rpc_error} =
             Browser.reconcile_job_id(ctx.job.id,
               dispatch: fn _request -> {:error, rpc_error} end
             )

    assert_receive {:browser_telemetry, @reconcile_event, _measurements, metadata}

    assert metadata == %{
             job_id: ctx.job.id,
             outcome: "error",
             failure_code: "node_offline"
           }

    refute inspect(metadata) =~ secret
  end

  test "artifact transfer emits bounded identity, mode, status, and outcome only", ctx do
    content = "# Deferred telemetry\n"
    manifest = manifest(ctx, content)

    assert {:ok, %Artifact{status: "pending"} = pending} =
             ArtifactService.register_pending(ctx.node.commander_id, manifest)

    dispatch = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "artifact_id" => pending.id,
           "sha256" => pending.sha256,
           "content_base64" => Base.encode64(content)
         }
       }}
    end

    assert {:ok, %Artifact{status: "verified"}} =
             ArtifactService.transfer_pending(pending,
               dispatch: dispatch,
               ack: fn _job, _artifact -> :ok end
             )

    assert_receive {:browser_telemetry, @artifact_event, measurements, metadata}
    assert measurements == %{count: 1}

    assert metadata == %{
             artifact_id: pending.id,
             job_id: ctx.job.id,
             transfer_mode: "remote_pending",
             status: "verified",
             outcome: "ok",
             failure_code: nil
           }

    refute inspect(metadata) =~ content
    refute Map.has_key?(metadata, :sha256)
    refute Map.has_key?(metadata, :payload)
    refute Map.has_key?(metadata, :url)
  end

  defp reconcile_result(ctx) do
    %{
      "central_job_id" => ctx.job.id,
      "remote_execution_id" => ctx.remote_id,
      "status" => "running",
      "phase" => "researching",
      "last_sequence" => 0,
      "artifacts" => [],
      "outbox" => %{"pending_artifact_count" => 0}
    }
  end

  defp manifest(ctx, content) do
    %ArtifactManifest{
      protocol_version: 1,
      artifact_id: Ecto.UUID.generate(),
      job_id: ctx.job.id,
      kind: "report.markdown",
      mime: "text/markdown",
      filename: "report.md",
      size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      transfer_mode: "remote_pending",
      metadata: %{"remote_execution_id" => ctx.remote_id}
    }
  end
end
