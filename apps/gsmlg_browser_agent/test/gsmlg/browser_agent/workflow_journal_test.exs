defmodule GSMLG.BrowserAgent.WorkflowJournalTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.Journal

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    name = String.to_atom("workflow_journal_#{System.unique_integer([:positive])}")
    path = Path.join(tmp_dir, "workflow.dets")

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: path,
        dets_name: name,
        max_workflow_entries: 3,
        max_unacked_events: 10,
        max_event_executions: 3
      )

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(name)
    end)

    %{journal: journal, path: path, name: name}
  end

  test "atomically claims central-job and workflow-scoped idempotency indexes", context do
    first = checkpoint("exec-1", "central-1", "idem-1", "fp-1")

    assert {:execute, ^first} = Journal.workflow_claim(context.journal, first, 1)
    assert {:replay, ^first} = Journal.workflow_claim(context.journal, first, 1)

    assert {:error, :central_job_id_collision} =
             Journal.workflow_claim(
               context.journal,
               checkpoint("exec-2", "central-1", "idem-2", "fp-2"),
               2
             )

    assert {:error, :workflow_idempotency_collision} =
             Journal.workflow_claim(
               context.journal,
               checkpoint("exec-3", "central-3", "idem-1", "fp-3"),
               2
             )

    assert {:ok, ^first} = Journal.workflow_by_central_job_id(context.journal, "central-1")

    assert {:ok, ^first} =
             Journal.workflow_get(context.journal, "00000000-0000-4000-8000-000000000001")
  end

  test "concurrent claims have one executor and one replay", context do
    claim = checkpoint("exec-1", "central-1", "idem-1", "same")

    results =
      1..2
      |> Task.async_stream(fn _ -> Journal.workflow_claim(context.journal, claim, 1) end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &match?({:execute, _}, &1)) == 1
    assert Enum.count(results, &match?({:replay, _}, &1)) == 1
  end

  test "max active workflow admission is durable and terminal updates free capacity", context do
    first = checkpoint("exec-1", "central-1", "idem-1", "fp-1")
    second = checkpoint("exec-2", "central-2", "idem-2", "fp-2")

    assert {:execute, ^first} = Journal.workflow_claim(context.journal, first, 1)

    assert {:error, :workflow_capacity_exceeded} =
             Journal.workflow_claim(context.journal, second, 1)

    terminal = %{first | status: :completed, runner_generation: "gen-1"}
    assert :ok = Journal.workflow_update(context.journal, terminal, "gen-1")
    assert {:execute, ^second} = Journal.workflow_claim(context.journal, second, 1)
  end

  test "generation fencing prevents a replaced runner from overwriting its checkpoint", context do
    first = checkpoint("exec-1", "central-1", "idem-1", "fp-1")
    assert {:execute, ^first} = Journal.workflow_claim(context.journal, first, 1)

    assert {:ok, claimed} =
             Journal.workflow_takeover(
               context.journal,
               "00000000-0000-4000-8000-000000000001",
               "gen-new"
             )

    assert claimed.runner_generation == "gen-new"

    assert {:error, :stale_workflow_generation} =
             Journal.workflow_update(context.journal, %{claimed | phase: :researching}, "gen-old")

    assert :ok =
             Journal.workflow_update(
               context.journal,
               %{claimed | phase: :researching},
               "gen-new"
             )
  end

  test "central-job index and checkpoints recover without an unbounded scan", context do
    first = checkpoint("exec-1", "central-1", "idem-1", "fp-1")
    assert {:execute, ^first} = Journal.workflow_claim(context.journal, first, 1)
    GenServer.stop(context.journal)

    assert {:ok, reopened} =
             Journal.start_link(
               name: nil,
               path: context.path,
               dets_name: context.name,
               max_workflow_entries: 3
             )

    assert {:ok, ^first} = Journal.workflow_by_central_job_id(reopened, "central-1")

    assert [{"00000000-0000-4000-8000-000000000001", ^first}] =
             Journal.workflow_list(reopened)
  end

  test "event append-once and cumulative ACK are execution-scoped and replayable", context do
    execution_1 = "00000000-0000-4000-8000-000000000001"
    execution_2 = "00000000-0000-4000-8000-000000000002"

    event = %{
      "event" => "workflow.started",
      "phase" => "inspect_auth",
      "metadata" => %{"central_job_id" => "central-1"},
      "occurred_at" => "2026-09-06T00:00:00Z"
    }

    assert {:ok, %{"sequence" => 1} = emitted} =
             Journal.append_event_once(context.journal, execution_1, "started", event)

    assert {:replay, ^emitted} =
             Journal.append_event_once(context.journal, execution_1, "started", event)

    assert {:ok, %{"sequence" => 1}} =
             Journal.append_event_once(context.journal, execution_2, "started", event)

    assert {:error, :event_ack_ahead} = Journal.ack_events(context.journal, execution_1, 99)
    assert {:error, :event_ack_ahead} = Journal.ack_events(context.journal, execution_1, 1)
    assert [%{"sequence" => 1}] = Journal.event_unacked(context.journal, execution_1)
    assert [%{"sequence" => 1}] = Journal.event_unacked(context.journal, execution_2)

    assert :ok = Journal.mark_event_emitted(context.journal, execution_1, 1)
    assert :ok = Journal.ack_events(context.journal, execution_1, 1)
    assert [] = Journal.event_unacked(context.journal, execution_1)
    assert [%{"sequence" => 1}] = Journal.event_unacked(context.journal, execution_2)

    assert Enum.sort(Journal.event_execution_ids(context.journal)) ==
             Enum.sort([execution_1, execution_2])
  end

  defp checkpoint(remote_id, central_id, idempotency_key, fingerprint) do
    remote_id =
      case remote_id do
        "exec-1" -> "00000000-0000-4000-8000-000000000001"
        "exec-2" -> "00000000-0000-4000-8000-000000000002"
        "exec-3" -> "00000000-0000-4000-8000-000000000003"
      end

    %{
      version: 1,
      remote_execution_id: remote_id,
      central_job_id: central_id,
      workflow: "gemini.deep_research/v1",
      idempotency_key: idempotency_key,
      request_fingerprint: fingerprint,
      status: :accepting,
      phase: :acquire_profile,
      runner_generation: "gen-1"
    }
  end
end
