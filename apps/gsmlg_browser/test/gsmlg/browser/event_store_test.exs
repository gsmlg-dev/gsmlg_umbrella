defmodule GSMLG.Browser.EventStoreTest do
  use GSMLG.Browser.DataCase, async: true

  alias GSMLG.Browser
  alias GSMLG.Browser.{Artifact, ArtifactService, EventStore, Job, JobEvent, Profile}
  alias GSMLG.Browser.Workers.ReconcileWorker
  alias GSMLG.Commander.Protocol.RPCResponse
  alias GSMLG.Commander.Protocol.EventAck
  alias GSMLG.Commander.Protocol.JobEvent, as: WireEvent

  setup do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    remote_id = Ecto.UUID.generate()
    job = job_fixture(actor, node, profile, %{status: "accepted", remote_execution_id: remote_id})

    %{actor: actor, node: node, profile: profile, job: job, remote_id: remote_id}
  end

  test "retains gaps, deduplicates, and ACKs only the highest contiguous committed sequence",
       ctx do
    assert {:ok, :subscribed} = Browser.subscribe(ctx.actor, {:job, ctx.job.id})

    ack = fn agent_id, %EventAck{} = event_ack ->
      persisted =
        Repo.aggregate(from(event in JobEvent, where: event.job_id == ^ctx.job.id), :count)

      send(self(), {:ack, agent_id, event_ack.highest_contiguous_sequence, persisted})
      :ok
    end

    assert {:ok, %{inserted?: true, highest_contiguous_sequence: 1}} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 1, "workflow.started"), ack: ack)

    assert_receive {:browser_job_changed, %{job_id: job_id, reason: :event, sequence: 1}}
    assert job_id == ctx.job.id
    assert_receive {:ack, _, 1, 1}

    third = event(ctx, 3, "workflow.phase_changed")

    assert {:ok, %{inserted?: true, highest_contiguous_sequence: 1}} =
             EventStore.ingest(ctx.node.commander_id, third, ack: ack)

    assert_receive {:browser_job_changed, %{reason: :event, sequence: 3}}
    assert_receive {:ack, _, 1, 2}

    assert {:ok, %{inserted?: false, highest_contiguous_sequence: 1}} =
             EventStore.ingest(ctx.node.commander_id, third, ack: ack)

    refute_receive {:browser_job_changed, %{sequence: 3}}
    assert_receive {:ack, _, 1, 2}

    assert {:ok, %{inserted?: true, highest_contiguous_sequence: 3}} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 2, "workflow.phase_changed"),
               ack: ack
             )

    assert_receive {:ack, _, 3, 3}
    assert Repo.get!(Job, ctx.job.id).last_remote_sequence == 3

    collision = %{third | phase: "different"}

    assert {:error, :event_sequence_conflict} =
             EventStore.ingest(ctx.node.commander_id, collision, ack: ack)
  end

  test "bounds gap admission and advances a large retained contiguous backlog in batches", ctx do
    ack = fn _agent, ack ->
      send(self(), {:batch_ack, ack.highest_contiguous_sequence})
      :ok
    end

    for sequence <- 2..5 do
      assert {:ok, %{highest_contiguous_sequence: 0}} =
               EventStore.ingest(
                 ctx.node.commander_id,
                 event(ctx, sequence, "workflow.phase_changed"),
                 ack: ack,
                 advance_limit: 2
               )
    end

    assert {:error, :event_gap_too_large} =
             EventStore.ingest(
               ctx.node.commander_id,
               event(ctx, 10_001, "workflow.phase_changed"),
               ack: ack,
               max_gap: 10_000
             )

    first = event(ctx, 1, "workflow.started")

    assert {:ok, %{highest_contiguous_sequence: 2}} =
             EventStore.ingest(ctx.node.commander_id, first,
               ack: ack,
               advance_limit: 2
             )

    assert {:ok, %{inserted?: false, highest_contiguous_sequence: 4}} =
             EventStore.ingest(ctx.node.commander_id, first,
               ack: ack,
               advance_limit: 2
             )

    assert {:ok, %{inserted?: false, highest_contiguous_sequence: 5}} =
             EventStore.ingest(ctx.node.commander_id, first,
               ack: ack,
               advance_limit: 2
             )
  end

  test "rejects mismatched agent, central job identity, and remote execution identity", ctx do
    ack = fn _agent, _ack -> send(self(), :acked) end

    assert {:error, :agent_mismatch} =
             EventStore.ingest("other-agent", event(ctx, 1, "workflow.started"), ack: ack)

    bad_central = %{
      event(ctx, 1, "workflow.started")
      | metadata: %{"central_job_id" => Ecto.UUID.generate()}
    }

    assert {:error, :job_mismatch} =
             EventStore.ingest(ctx.node.commander_id, bad_central, ack: ack)

    bad_remote = %{event(ctx, 1, "workflow.started") | remote_execution_id: Ecto.UUID.generate()}

    assert {:error, :unknown_execution} =
             EventStore.ingest(ctx.node.commander_id, bad_remote, ack: ack)

    assert Repo.aggregate(JobEvent, :count) == 0
    refute_received :acked
  end

  test "applies only contiguous legal state changes and keeps terminal jobs immutable", ctx do
    ack = fn _agent, _ack -> :ok end

    assert {:ok, _} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 2, "workflow.completed"),
               ack: ack
             )

    assert Repo.get!(Job, ctx.job.id).status == "accepted"

    assert {:ok, _} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 1, "workflow.started"), ack: ack)

    assert Repo.get!(Job, ctx.job.id).status == "collecting_artifacts"

    Repo.update_all(from(job in Job, where: job.id == ^ctx.job.id),
      set: [status: "completed", completed_at: DateTime.utc_now()]
    )

    assert {:error, :job_terminal} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 3, "workflow.phase_changed"),
               ack: ack
             )

    assert Repo.aggregate(JobEvent, :count) == 2
  end

  test "intervention atomically hands the workflow profile to manual authority and schedules mapping reconcile",
       ctx do
    Repo.update_all(from(profile in Profile, where: profile.id == ^ctx.profile.id),
      set: [automation_status: "leased"]
    )

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{highest_contiguous_sequence: 1}} =
               EventStore.ingest(
                 ctx.node.commander_id,
                 event(ctx, 1, "workflow.started"),
                 ack: fn _agent, _ack -> :ok end
               )

      assert {:ok, %{highest_contiguous_sequence: 2}} =
               EventStore.ingest(
                 ctx.node.commander_id,
                 event(ctx, 2, "intervention.required"),
                 ack: fn _agent, _ack -> :ok end
               )
    end)

    assert %Job{status: "waiting_human"} = Repo.get!(Job, ctx.job.id)
    assert %Profile{automation_status: "manual"} = Repo.get!(Profile, ctx.profile.id)

    assert Repo.aggregate(
             from(oban_job in Oban.Job,
               where:
                 oban_job.worker == ^inspect(ReconcileWorker) and
                   oban_job.args["job_id"] == ^ctx.job.id
             ),
             :count
           ) == 1
  end

  test "a terminal reconciliation still accepts only its confirmed historical replay", ctx do
    reconcile = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => ctx.job.id,
           "remote_execution_id" => ctx.remote_id,
           "status" => "failed",
           "phase" => "failed",
           "last_sequence" => 2,
           "artifacts" => [],
           "outbox" => %{"pending_artifact_count" => 0}
         }
       }}
    end

    assert {:ok, %Job{status: "failed", completed_at: completed_at}} =
             Browser.reconcile_job_id(ctx.job.id, dispatch: reconcile)

    assert {:ok, %{highest_contiguous_sequence: 1}} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 1, "workflow.started"),
               ack: fn _agent, _ack -> :ok end
             )

    assert {:ok, %{highest_contiguous_sequence: 2}} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 2, "workflow.failed"),
               ack: fn _agent, _ack -> :ok end
             )

    assert %Job{
             status: "failed",
             phase: "failed",
             completed_at: ^completed_at,
             last_remote_sequence: 2
           } = Repo.get!(Job, ctx.job.id)

    assert {:error, :job_terminal} =
             EventStore.ingest(ctx.node.commander_id, event(ctx, 3, "workflow.phase_changed"),
               ack: fn _agent, _ack -> :ok end
             )
  end

  test "artifact events durably trigger manifest reconciliation and completion waits for verified ACKs",
       ctx do
    Repo.update_all(from(job in Job, where: job.id == ^ctx.job.id),
      set: [output_formats: ["report.markdown"]]
    )

    Repo.update_all(from(profile in Profile, where: profile.id == ^ctx.profile.id),
      set: [automation_status: "leased"]
    )

    content = "# Complete only after ACK\n"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    artifact_id = Ecto.UUID.generate()
    ack_event = fn _agent, _ack -> :ok end
    completed = event(ctx, 4, "workflow.completed")

    available =
      ctx
      |> event(2, "artifact.available")
      |> Map.put(:metadata, %{
        "central_job_id" => ctx.job.id,
        "artifact_id" => artifact_id,
        "content_hash" => hash,
        "kind" => "report.markdown",
        "transfer_mode" => "remote_pending"
      })

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{highest_contiguous_sequence: 0}} =
               EventStore.ingest(ctx.node.commander_id, completed, ack: ack_event)
    end)

    assert %Job{status: "accepted", completed_at: nil, last_remote_sequence: 0} =
             Repo.get!(Job, ctx.job.id)

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "leased"
    refute Repo.get(Artifact, artifact_id)

    assert Repo.aggregate(
             from(oban_job in Oban.Job,
               where:
                 oban_job.worker == ^inspect(ReconcileWorker) and
                   oban_job.args["job_id"] == ^ctx.job.id
             ),
             :count
           ) == 1

    reconcile = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => ctx.job.id,
           "remote_execution_id" => ctx.remote_id,
           "status" => "completed",
           "phase" => "done",
           "last_sequence" => 4,
           "artifacts" => [
             %{
               "protocol_version" => 1,
               "artifact_id" => artifact_id,
               "job_id" => ctx.job.id,
               "kind" => "report.markdown",
               "mime" => "text/markdown",
               "filename" => "report.md",
               "size" => byte_size(content),
               "sha256" => hash,
               "transfer_mode" => "remote_pending",
               "metadata" => %{"remote_execution_id" => ctx.remote_id}
             }
           ],
           "outbox" => %{"pending_artifact_count" => 1}
         }
       }}
    end

    assert {:ok, %Job{status: "collecting_artifacts"}} =
             Browser.reconcile_job_id(ctx.job.id, dispatch: reconcile)

    assert %Artifact{status: "pending", ack_status: "not_ready"} =
             pending =
             Repo.get!(Artifact, artifact_id)

    dispatch = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "artifact_id" => artifact_id,
           "sha256" => hash,
           "content_base64" => Base.encode64(content)
         }
       }}
    end

    remote_ack = fn job, artifact ->
      assert Repo.get!(Artifact, artifact.id).status == "verified"
      assert Repo.get!(Job, job.id).status == "collecting_artifacts"
      :ok
    end

    assert {:ok, %Artifact{status: "verified", ack_status: "acked"}} =
             ArtifactService.transfer_pending(pending, dispatch: dispatch, ack: remote_ack)

    assert %Job{status: "collecting_artifacts", completed_at: nil, last_remote_sequence: 0} =
             Repo.get!(Job, ctx.job.id)

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "leased"

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %{highest_contiguous_sequence: 1}} =
               EventStore.ingest(ctx.node.commander_id, event(ctx, 1, "workflow.started"),
                 ack: ack_event
               )

      assert {:ok, %{highest_contiguous_sequence: 2}} =
               EventStore.ingest(ctx.node.commander_id, available, ack: ack_event)

      assert {:ok, %{highest_contiguous_sequence: 4}} =
               EventStore.ingest(ctx.node.commander_id, event(ctx, 3, "result.available"),
                 ack: ack_event
               )
    end)

    assert Repo.aggregate(
             from(oban_job in Oban.Job,
               where:
                 oban_job.worker == ^inspect(ReconcileWorker) and
                   oban_job.args["job_id"] == ^ctx.job.id
             ),
             :count
           ) == 3

    assert %Job{status: "completed", completed_at: %DateTime{}} = Repo.get!(Job, ctx.job.id)
    assert Repo.get!(Profile, ctx.profile.id).automation_status == "available"
  end

  test "rejects sensitive or unbounded event metadata before persistence", ctx do
    ack = fn _agent, _ack -> :ok end

    sensitive = %{
      event(ctx, 1, "workflow.started")
      | metadata: %{"central_job_id" => ctx.job.id, "cookie" => "secret"}
    }

    assert {:error, :sensitive_metadata} =
             EventStore.ingest(ctx.node.commander_id, sensitive, ack: ack)

    oversized = %{
      event(ctx, 1, "workflow.started")
      | metadata: %{
          "central_job_id" => ctx.job.id,
          "failure_code" => String.duplicate("x", 4_097)
        }
    }

    assert {:error, :invalid_metadata} =
             EventStore.ingest(ctx.node.commander_id, oversized, ack: ack)
  end

  test "a failed post-commit ACK does not suppress or duplicate the redacted invalidation", ctx do
    assert {:ok, :subscribed} = Browser.subscribe(ctx.actor, {:job, ctx.job.id})
    wire = event(ctx, 1, "workflow.started")

    assert {:error, :node_offline} =
             EventStore.ingest(ctx.node.commander_id, wire,
               ack: fn _agent, _ack -> {:error, :node_offline} end
             )

    assert Repo.get_by!(JobEvent, job_id: ctx.job.id, sequence: 1)

    assert_receive {:browser_job_changed, %{job_id: job_id, reason: :event, sequence: 1}}

    assert job_id == ctx.job.id

    assert {:ok, %{inserted?: false, highest_contiguous_sequence: 1}} =
             EventStore.ingest(ctx.node.commander_id, wire, ack: fn _agent, _ack -> :ok end)

    refute_receive {:browser_job_changed, %{sequence: 1}}
  end

  defp event(ctx, sequence, name) do
    %WireEvent{
      protocol_version: 1,
      remote_execution_id: ctx.remote_id,
      sequence: sequence,
      event: name,
      phase: "researching",
      metadata: %{"central_job_id" => ctx.job.id},
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
