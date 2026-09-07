defmodule GSMLG.Browser.OrchestrationTest do
  use GSMLG.Browser.DataCase, async: false

  alias GSMLG.Browser.{Artifact, EventConsumer, JobEvent, Scheduler}
  alias GSMLG.Browser.Workers.{ReconcileSweepWorker, RetentionWorker}
  alias GSMLG.Commander.Protocol.JobEvent, as: WireEvent

  test "event consumer subscribes to the Commander event stream" do
    test_pid = self()

    consumer =
      start_supervised!(
        {EventConsumer,
         name: nil,
         event_store: fn agent_id, event ->
           send(test_pid, {:consumed, agent_id, event})
           {:ok, %{}}
         end}
      )

    event = %WireEvent{
      protocol_version: 1,
      remote_execution_id: Ecto.UUID.generate(),
      sequence: 1,
      event: "workflow.started",
      phase: nil,
      metadata: %{"central_job_id" => Ecto.UUID.generate()},
      occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    :ok =
      Phoenix.PubSub.broadcast(
        GSMLG.PubSub,
        "commander:events",
        {:commander_job_event, "agent-1", event}
      )

    assert_receive {:consumed, "agent-1", ^event}
    assert Process.alive?(consumer)
  end

  test "scheduler emits only the unique bounded sweep and retention activations" do
    test_pid = self()

    scheduler =
      start_supervised!(
        {Scheduler,
         name: nil,
         interval_ms: 60_000,
         insert: fn changeset ->
           send(test_pid, {:scheduled, get_change(changeset, :worker)})
           {:ok, %{}}
         end}
      )

    assert_receive {:scheduled, "GSMLG.Browser.Workers.ReconcileSweepWorker"}
    assert_receive {:scheduled, "GSMLG.Browser.Workers.RetentionWorker"}
    refute_receive {:scheduled, _other}
    assert Process.alive?(scheduler)

    incomplete = [:suspended, :available, :scheduled, :executing, :retryable]
    assert ReconcileSweepWorker.new(%{}).changes.unique[:states] == incomplete
    assert RetentionWorker.new(%{}).changes.unique[:states] == incomplete
  end

  test "retention deletes only old events of terminal jobs in a bounded pass" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    terminal_remote = Ecto.UUID.generate()
    active_remote = Ecto.UUID.generate()

    terminal =
      job_fixture(actor, node, profile, %{
        status: "completed",
        remote_execution_id: terminal_remote,
        completed_at: DateTime.add(DateTime.utc_now(), -40, :day)
      })

    active =
      job_fixture(actor, node, profile, %{status: "running", remote_execution_id: active_remote})

    terminal_event = event_fixture(terminal, terminal_remote)
    active_event = event_fixture(active, active_remote)
    old = DateTime.add(DateTime.utc_now(), -40, :day)

    Repo.update_all(
      from(event in JobEvent, where: event.id in ^[terminal_event.id, active_event.id]),
      set: [inserted_at: old]
    )

    assert :ok = RetentionWorker.perform(%Oban.Job{args: %{}})
    refute Repo.get(JobEvent, terminal_event.id)
    assert Repo.get(JobEvent, active_event.id)
  end

  test "the reconciliation sweep queries artifact queues using persisted fields" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    remote_id = Ecto.UUID.generate()
    job = job_fixture(actor, node, profile, %{status: "running", remote_execution_id: remote_id})

    %Artifact{id: Ecto.UUID.generate()}
    |> Artifact.manifest_changeset(%{
      job_id: job.id,
      kind: "report.markdown",
      mime: "text/markdown",
      filename: "report.md",
      size: 1,
      sha256: :crypto.hash(:sha256, "x") |> Base.encode16(case: :lower),
      transfer_mode: "remote_pending",
      status: "pending",
      metadata: %{"remote_execution_id" => remote_id}
    })
    |> Repo.insert!()

    assert :ok = ReconcileSweepWorker.perform(%Oban.Job{args: %{}})
  end

  defp event_fixture(job, remote_id) do
    %JobEvent{}
    |> JobEvent.changeset(%{
      job_id: job.id,
      remote_execution_id: remote_id,
      sequence: 1,
      event: "workflow.started",
      metadata: %{"central_job_id" => job.id},
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end
end
