defmodule GSMLG.BrowserAgent.JournalOutboxTest do
  use ExUnit.Case, async: false

  alias GSMLG.BrowserAgent.{ArtifactOutbox, ArtifactStore, EventOutbox, Journal, RequestDedup}
  alias GSMLG.BrowserAgent.ArtifactOutbox.Recovery, as: ArtifactRecovery
  alias GSMLG.Commander.Protocol.RPCRequest

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "journal.dets")
    dets_name = :browser_agent_journal_test
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets_name)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(dets_name)
    end)

    %{journal: journal, path: path, dets_name: dets_name, state_dir: tmp_dir}
  end

  test "writes versioned composite records synchronously before replying", context do
    assert :ok = Journal.put(context.journal, :checkpoint, "job-1", %{phase: "running"})

    assert [{{{:gsmlg_browser_agent, 1}, :checkpoint, "job-1"}, %{version: 1, value: _}}] =
             :dets.lookup(
               context.dets_name,
               {{:gsmlg_browser_agent, 1}, :checkpoint, "job-1"}
             )

    ref = Process.monitor(context.journal)
    Process.unlink(context.journal)
    Process.exit(context.journal, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    assert {:ok, %{phase: "running"}} = Journal.get(reopened, :checkpoint, "job-1")
    GenServer.stop(reopened)
  end

  test "request dedup survives reopen and rejects request/payload collisions", context do
    request = request("request-1", "idem-1", "profile.launch", %{"profile_id" => "profile-1"})
    assert {:ok, generation} = RequestDedup.begin_generation(context.journal)
    assert {:ok, ^generation} = Journal.get(context.journal, :metadata, :request_generation)

    assert :execute = RequestDedup.claim(context.journal, request, generation)

    assert {:in_progress, "request-1"} =
             RequestDedup.claim(context.journal, request, generation)

    assert {:error, :request_not_claimed} =
             RequestDedup.complete(
               context.journal,
               %{request | operation: "profile.stop"},
               {:ok, %{"status" => "stopped"}}
             )

    assert :ok = RequestDedup.complete(context.journal, request, {:ok, %{"status" => "running"}})

    GenServer.stop(context.journal)

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    assert {:ok, reopened_generation} = RequestDedup.begin_generation(reopened)
    refute reopened_generation == generation

    assert {:replay, {:ok, %{"status" => "running"}}} =
             RequestDedup.claim(reopened, request, reopened_generation)

    assert {:error, :request_payload_collision} =
             RequestDedup.claim(
               reopened,
               %{request | payload: %{"profile_id" => "other"}},
               reopened_generation
             )

    assert {:error, :idempotency_payload_collision} =
             RequestDedup.claim(
               reopened,
               %{request | request_id: "request-2", operation: "profile.stop"},
               reopened_generation
             )

    GenServer.stop(reopened)
  end

  test "request journal evicts only completed entries and fails closed when live claims fill capacity",
       context do
    GenServer.stop(context.journal)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        max_request_entries: 2
      )

    {:ok, generation} = RequestDedup.begin_generation(journal)
    first = request("request-cap-1", "idem-cap-1", "profile.status", %{"profile_id" => "a"})
    second = request("request-cap-2", "idem-cap-2", "profile.status", %{"profile_id" => "b"})
    third = request("request-cap-3", "idem-cap-3", "profile.status", %{"profile_id" => "c"})
    fourth = request("request-cap-4", "idem-cap-4", "profile.status", %{"profile_id" => "d"})

    assert :execute = RequestDedup.claim(journal, first, generation)
    assert :ok = RequestDedup.complete(journal, first, {:ok, %{"status" => "stopped"}})
    assert :execute = RequestDedup.claim(journal, second, generation)
    assert :execute = RequestDedup.claim(journal, third, generation)

    assert :error = Journal.get(journal, :request_dedup, first.request_id)
    assert :error = Journal.get(journal, :request_idempotency, first.idempotency_key)
    assert length(Journal.list(journal, :request_dedup)) == 2
    assert length(Journal.list(journal, :request_idempotency)) == 2
    assert {:error, :request_capacity_exceeded} = RequestDedup.claim(journal, fourth, generation)

    GenServer.stop(journal)

    {:ok, reopened} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        max_request_entries: 2
      )

    {:ok, reopened_generation} = RequestDedup.begin_generation(reopened)

    assert {:error, :request_capacity_exceeded} =
             RequestDedup.claim(reopened, fourth, reopened_generation)

    assert length(Journal.list(reopened, :request_dedup)) == 2
    assert length(Journal.list(reopened, :request_idempotency)) == 2
    GenServer.stop(reopened)
  end

  test "journal fails closed when DETS cannot open or sync", context do
    GenServer.stop(context.journal)
    Process.flag(:trap_exit, true)

    assert {:error, {:journal_open_failed, _reason}} =
             Journal.start_link(
               name: nil,
               path: context.state_dir,
               dets_name: context.dets_name
             )

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        sync: fn _table -> {:error, :disk_full} end
      )

    Process.unlink(journal)
    ref = Process.monitor(journal)

    assert {:error, {:journal_write_failed, :disk_full}} =
             RequestDedup.begin_generation(journal)

    assert_receive {:DOWN, ^ref, :process, ^journal, _reason}
  end

  test "a sync-failed claim terminates its generation and can recover after reopen", context do
    GenServer.stop(context.journal)
    {:ok, sync_calls} = Agent.start_link(fn -> 0 end)

    sync = fn table ->
      case Agent.get_and_update(sync_calls, fn count -> {count, count + 1} end) do
        0 -> :dets.sync(table)
        _later -> {:error, :disk_full}
      end
    end

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        sync: sync
      )

    assert {:ok, generation} = RequestDedup.begin_generation(journal)
    Process.unlink(journal)
    ref = Process.monitor(journal)

    request =
      request("sync-failed-request", "sync-failed-idem", "profile.stop", %{"profile_id" => "a"})

    assert {:error, {:journal_write_failed, :disk_full}} =
             RequestDedup.claim(journal, request, generation)

    assert_receive {:DOWN, ^ref, :process, ^journal, _reason}

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    {:ok, next_generation} = RequestDedup.begin_generation(reopened)
    refute next_generation == generation

    retry = RequestDedup.claim(reopened, request, next_generation)
    assert retry == :execute or match?({:recover, %{request_id: "sync-failed-request"}}, retry)

    GenServer.stop(reopened)
    Agent.stop(sync_calls)
  end

  test "only one caller recovers a prior-generation running request", context do
    request =
      request("request-recovery", "idem-recovery", "profile.stop", %{"profile_id" => "profile-1"})

    assert {:ok, prior_generation} = RequestDedup.begin_generation(context.journal)
    assert :execute = RequestDedup.claim(context.journal, request, prior_generation)
    assert {:ok, current_generation} = RequestDedup.begin_generation(context.journal)

    assert {:recover, %{request_id: "request-recovery"}} =
             RequestDedup.claim(context.journal, request, current_generation)

    assert {:in_progress, "request-recovery"} =
             RequestDedup.claim(context.journal, request, current_generation)

    assert :ok = RequestDedup.defer(context.journal, request)

    assert {:recover, %{request_id: "request-recovery"}} =
             RequestDedup.claim(context.journal, request, current_generation)
  end

  test "event sequence is monotonic across restart and cumulative ACK prunes only acknowledged events",
       context do
    execution_id = "00000000-0000-4000-8000-000000000011"

    assert {:ok, %{"sequence" => 1, "event" => "started"}} =
             EventOutbox.append(context.journal, execution_id, %{"event" => "started"})

    assert {:ok, %{"sequence" => 2, "event" => "progress"}} =
             EventOutbox.append(context.journal, execution_id, %{"event" => "progress"})

    assert :ok = Journal.mark_event_emitted(context.journal, execution_id, 1)
    assert :ok = EventOutbox.ack(context.journal, execution_id, 1)
    assert [%{"sequence" => 2}] = EventOutbox.unacked(context.journal, execution_id)

    GenServer.stop(context.journal)

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    assert {:ok, %{"sequence" => 3}} =
             EventOutbox.append(reopened, execution_id, %{"event" => "complete"})

    assert {:error, :event_ack_ahead} = EventOutbox.ack(reopened, execution_id, 99)
    assert :ok = Journal.mark_event_emitted(reopened, execution_id, 2)
    assert :ok = Journal.mark_event_emitted(reopened, execution_id, 3)
    assert :ok = EventOutbox.ack(reopened, execution_id, 3)
    assert [] = EventOutbox.unacked(reopened, execution_id)
    GenServer.stop(reopened)
  end

  test "event journal bounds executions and unacked events without resetting sequence after ACK",
       context do
    execution_a = "00000000-0000-4000-8000-000000000012"
    execution_b = "00000000-0000-4000-8000-000000000013"
    GenServer.stop(context.journal)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        max_event_executions: 1,
        max_unacked_events: 2
      )

    assert {:ok, %{"sequence" => 1}} = EventOutbox.append(journal, execution_a, %{})
    assert {:ok, %{"sequence" => 2}} = EventOutbox.append(journal, execution_a, %{})
    assert {:error, :event_capacity_exceeded} = EventOutbox.append(journal, execution_a, %{})
    assert :ok = Journal.mark_event_emitted(journal, execution_a, 1)
    assert :ok = Journal.mark_event_emitted(journal, execution_a, 2)
    assert :ok = EventOutbox.ack(journal, execution_a, 2)
    assert {:ok, %{"sequence" => 3}} = EventOutbox.append(journal, execution_a, %{})
    assert :ok = Journal.mark_event_emitted(journal, execution_a, 3)
    assert :ok = EventOutbox.ack(journal, execution_a, 3)

    assert {:error, :event_execution_capacity_exceeded} =
             EventOutbox.append(journal, execution_b, %{})

    GenServer.stop(journal)

    {:ok, reopened} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        max_event_executions: 1,
        max_unacked_events: 2
      )

    assert {:ok, %{"sequence" => 4}} = EventOutbox.append(reopened, execution_a, %{})
    assert :ok = Journal.mark_event_emitted(reopened, execution_a, 4)
    assert :ok = EventOutbox.ack(reopened, execution_a, 4)
    assert :ok = EventOutbox.cleanup_execution(reopened, execution_a)
    assert {:ok, %{"sequence" => 1}} = EventOutbox.append(reopened, execution_b, %{})
    assert length(Journal.list(reopened, :event_sequence)) == 1
    assert length(Journal.list(reopened, :event_outbox)) == 1
    GenServer.stop(reopened)
  end

  test "artifact outbox persists integrity manifests and deletes content only after central ACK",
       context do
    content = "private artifact content"

    attrs = %{
      "artifact_id" => "11111111-1111-1111-1111-111111111111",
      "job_id" => "22222222-2222-2222-2222-222222222222",
      "kind" => "report.markdown",
      "mime" => "text/markdown",
      "filename" => "report.md",
      "metadata" => %{}
    }

    assert {:ok, manifest} =
             ArtifactOutbox.put(context.journal, context.state_dir, attrs, content,
               max_bytes: 1024
             )

    assert manifest["size"] == byte_size(content)
    assert manifest["sha256"] == Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    assert manifest["transfer_mode"] == "remote_pending"
    refute JSON.encode!(manifest) =~ content
    refute Map.has_key?(manifest, "path")

    path = ArtifactStore.path(context.state_dir, attrs["artifact_id"])
    assert File.read!(path) == content
    assert [^manifest] = ArtifactOutbox.pending(context.journal)

    assert {:error, :artifact_ack_mismatch} =
             ArtifactOutbox.ack(context.journal, attrs["artifact_id"], "bad-sha")

    assert File.exists?(path)

    assert :ok =
             ArtifactOutbox.ack(
               context.journal,
               attrs["artifact_id"],
               manifest["sha256"]
             )

    refute File.exists?(path)
    assert [] = ArtifactOutbox.pending(context.journal)
  end

  test "artifact store rejects oversized content before creating outbox state", context do
    attrs = %{
      "artifact_id" => "33333333-3333-3333-3333-333333333333",
      "job_id" => "44444444-4444-4444-4444-444444444444",
      "kind" => "download",
      "mime" => "application/octet-stream",
      "filename" => "large.bin",
      "metadata" => %{}
    }

    assert {:error, :artifact_too_large} =
             ArtifactOutbox.put(context.journal, context.state_dir, attrs, "123456", max_bytes: 5)

    refute File.exists?(ArtifactStore.path(context.state_dir, attrs["artifact_id"]))
    assert [] = ArtifactOutbox.pending(context.journal)
  end

  test "artifact write is removed if the journal cannot durably accept it", context do
    GenServer.stop(context.journal)

    {:ok, failing_journal} =
      Journal.start_link(
        name: nil,
        path: context.path,
        dets_name: context.dets_name,
        sync: fn _table -> {:error, :disk_full} end
      )

    Process.unlink(failing_journal)
    ref = Process.monitor(failing_journal)

    attrs = %{
      "artifact_id" => "55555555-5555-5555-5555-555555555555",
      "job_id" => "66666666-6666-6666-6666-666666666666",
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "metadata" => %{}
    }

    assert {:error, {:journal_write_failed, :disk_full}} =
             ArtifactOutbox.put(failing_journal, context.state_dir, attrs, "sensitive")

    refute File.exists?(ArtifactStore.path(context.state_dir, attrs["artifact_id"]))
    assert_receive {:DOWN, ^ref, :process, ^failing_journal, _reason}
  end

  test "artifact rename is cleaned up when directory metadata cannot be synced", context do
    attrs = %{
      "artifact_id" => "77777777-7777-7777-7777-777777777777",
      "job_id" => "88888888-8888-8888-8888-888888888888",
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "metadata" => %{}
    }

    test_pid = self()

    assert {:error, :directory_sync_failed} =
             ArtifactOutbox.put(context.journal, context.state_dir, attrs, "sensitive",
               directory_sync: fn directory ->
                 send(test_pid, {:directory_sync, directory})
                 {:error, :directory_sync_failed}
               end
             )

    assert_receive {:directory_sync, directory}
    assert directory == Path.join(context.state_dir, "artifacts")
    refute File.exists?(ArtifactStore.path(context.state_dir, attrs["artifact_id"]))
    assert [] = ArtifactOutbox.pending(context.journal)
  end

  test "artifact reservation survives crash before file creation and recovery removes its tombstone",
       context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000001")
    path = ArtifactStore.path(context.state_dir, attrs["artifact_id"])
    parent = self()

    {writer, writer_ref} =
      spawn_monitor(fn ->
        ArtifactOutbox.put(context.journal, context.state_dir, attrs, "content",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:reserved_before_creation, self()})
              receive do: (:crash -> exit(:simulated_writer_crash))

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:reserved_before_creation, ^writer}, 5_000

    assert {:ok, %{status: :writing}} =
             Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    refute File.exists?(path)
    Process.unlink(context.journal)
    journal_ref = Process.monitor(context.journal)
    Process.exit(context.journal, :kill)
    assert_receive {:DOWN, ^journal_ref, :process, _, :killed}
    send(writer, :crash)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :simulated_writer_crash}

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    assert :ok = ArtifactOutbox.recover(reopened, context.state_dir)
    assert :error = Journal.get(reopened, :artifact_outbox, attrs["artifact_id"])
    refute File.exists?(path)
    GenServer.stop(reopened)
  end

  test "artifact reservation with a committed file is promoted after reopen", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000002")
    path = ArtifactStore.path(context.state_dir, attrs["artifact_id"])
    parent = self()

    {writer, writer_ref} =
      spawn_monitor(fn ->
        ArtifactOutbox.put(context.journal, context.state_dir, attrs, "committed",
          checkpoint: fn
            :after_commit ->
              send(parent, {:committed_before_crash, self()})
              receive do: (:crash -> exit(:simulated_writer_crash))

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:committed_before_crash, ^writer}, 5_000

    assert File.read!(path) == "committed"

    assert {:ok, %{status: :writing}} =
             Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    Process.unlink(context.journal)
    journal_ref = Process.monitor(context.journal)
    Process.exit(context.journal, :kill)
    assert_receive {:DOWN, ^journal_ref, :process, _, :killed}
    send(writer, :crash)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :simulated_writer_crash}

    {:ok, reopened} =
      Journal.start_link(name: nil, path: context.path, dets_name: context.dets_name)

    assert :ok = ArtifactOutbox.recover(reopened, context.state_dir)
    assert [manifest] = ArtifactOutbox.pending(reopened)
    assert manifest["artifact_id"] == attrs["artifact_id"]
    assert {:ok, "committed"} = ArtifactOutbox.read(reopened, attrs["artifact_id"])
    GenServer.stop(reopened)
  end

  test "artifact commit is atomically no-replace under concurrent writers", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000003")
    {:ok, first} = ArtifactStore.prepare(context.state_dir, attrs, "first")
    {:ok, second} = ArtifactStore.prepare(context.state_dir, attrs, "second")
    parent = self()

    writer = fn entry, content ->
      Task.async(fn ->
        ArtifactStore.commit(entry, content,
          before_link: fn ->
            send(parent, {:ready_to_link, self()})
            receive do: (:link -> :ok)
          end
        )
      end)
    end

    first_task = writer.(first, "first")
    second_task = writer.(second, "second")
    assert_receive {:ready_to_link, first_writer}, 5_000
    assert_receive {:ready_to_link, second_writer}, 5_000
    send(first_writer, :link)
    send(second_writer, :link)

    results = [Task.await(first_task), Task.await(second_task)]
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert Enum.count(results, &(&1 == {:error, :artifact_exists})) == 1
    assert File.read!(first.path) in ["first", "second"]
  end

  test "artifact ACK keeps its tombstone until deletion metadata is durable", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000004")
    assert {:ok, manifest} = ArtifactOutbox.put(context.journal, context.state_dir, attrs, "done")
    path = ArtifactStore.path(context.state_dir, attrs["artifact_id"])

    assert {:error, :directory_sync_failed} =
             ArtifactOutbox.ack(context.journal, attrs["artifact_id"], manifest["sha256"],
               directory_sync: fn _directory -> {:error, :directory_sync_failed} end
             )

    refute File.exists?(path)

    assert {:ok, %{status: :acked}} =
             Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    assert :ok = ArtifactOutbox.recover(context.journal, context.state_dir)
    assert :error = Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])
  end

  test "artifact reservation rejects a concurrent duplicate before either file can be overwritten",
       context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000005")
    parent = self()

    first =
      Task.async(fn ->
        ArtifactOutbox.put(context.journal, context.state_dir, attrs, "first",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:reserved, self()})
              receive do: (:continue -> :ok)

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:reserved, first_writer}, 1_000

    assert {:error, :artifact_exists} =
             ArtifactOutbox.put(context.journal, context.state_dir, attrs, "second")

    send(first_writer, :continue)
    assert {:ok, manifest} = Task.await(first)
    assert {:ok, "first"} = ArtifactOutbox.read(context.journal, attrs["artifact_id"])
    assert manifest["sha256"] == Base.encode16(:crypto.hash(:sha256, "first"), case: :lower)
  end

  test "periodic recovery cannot claim or discard a live artifact writer", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000007")
    parent = self()

    writer =
      Task.async(fn ->
        ArtifactOutbox.put(context.journal, context.state_dir, attrs, "live-content",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:live_reservation, self()})
              receive do: (:continue -> :ok)

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:live_reservation, writer_pid}, 1_000
    assert :ok = ArtifactOutbox.recover(context.journal, context.state_dir, stale_after_ms: 0)

    assert {:ok, %{status: :writing}} =
             Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    send(writer_pid, :continue)
    assert {:ok, manifest} = Task.await(writer)
    assert [^manifest] = ArtifactOutbox.pending(context.journal)

    assert {:ok, "live-content"} =
             ArtifactOutbox.read(context.journal, attrs["artifact_id"])
  end

  test "a live artifact writer is adopted across a Journal-only restart", context do
    GenServer.stop(context.journal)
    name = unique_journal_name()

    {:ok, journal} =
      Journal.start_link(name: name, path: context.path, dets_name: context.dets_name)

    attrs = artifact_attrs("90000000-0000-0000-0000-000000000009")
    parent = self()

    writer =
      Task.async(fn ->
        ArtifactOutbox.put(name, context.state_dir, attrs, "survives-journal-restart",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:restart_reservation, self()})
              receive do: (:continue -> :ok)

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:restart_reservation, writer_pid}, 5_000
    Process.unlink(journal)
    journal_ref = Process.monitor(journal)
    Process.exit(journal, :kill)
    assert_receive {:DOWN, ^journal_ref, :process, ^journal, :killed}

    {:ok, reopened} =
      Journal.start_link(name: name, path: context.path, dets_name: context.dets_name)

    assert :ok = ArtifactOutbox.recover(name, context.state_dir, stale_after_ms: 0)

    assert {:ok, %{status: :writing, owner_pid: ^writer_pid}} =
             Journal.get(name, :artifact_outbox, attrs["artifact_id"])

    send(writer_pid, :continue)
    assert {:ok, manifest} = Task.await(writer)
    assert [^manifest] = ArtifactOutbox.pending(name)

    assert {:ok, "survives-journal-restart"} =
             ArtifactOutbox.read(name, attrs["artifact_id"])

    GenServer.stop(reopened)
  end

  test "an adopted artifact writer becomes recoverable when it dies", context do
    GenServer.stop(context.journal)
    name = unique_journal_name()

    {:ok, journal} =
      Journal.start_link(name: name, path: context.path, dets_name: context.dets_name)

    attrs = artifact_attrs("90000000-0000-0000-0000-000000000010")
    parent = self()

    {writer, writer_ref} =
      spawn_monitor(fn ->
        ArtifactOutbox.put(name, context.state_dir, attrs, "never-committed",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:adopted_reservation, self()})
              receive do: (:die -> exit(:simulated_writer_crash))

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:adopted_reservation, ^writer}, 5_000
    Process.unlink(journal)
    journal_ref = Process.monitor(journal)
    Process.exit(journal, :kill)
    assert_receive {:DOWN, ^journal_ref, :process, ^journal, :killed}

    {:ok, reopened} =
      Journal.start_link(name: name, path: context.path, dets_name: context.dets_name)

    assert :ok = ArtifactOutbox.recover(name, context.state_dir, stale_after_ms: 0)
    send(writer, :die)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, :simulated_writer_crash}

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :orphaned}},
        Journal.get(name, :artifact_outbox, attrs["artifact_id"])
      )
    end)

    assert :ok = ArtifactOutbox.recover(name, context.state_dir)
    assert :error = Journal.get(name, :artifact_outbox, attrs["artifact_id"])
    GenServer.stop(reopened)
  end

  test "writer death makes its durable reservation recoverable", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000008")
    parent = self()

    {writer, ref} =
      spawn_monitor(fn ->
        ArtifactOutbox.put(context.journal, context.state_dir, attrs, "never-written",
          checkpoint: fn
            :after_reserve ->
              send(parent, {:dying_reservation, self()})
              receive do: (:die -> exit(:simulated_writer_crash))

            _checkpoint ->
              :ok
          end
        )
      end)

    assert_receive {:dying_reservation, ^writer}, 1_000
    send(writer, :die)
    assert_receive {:DOWN, ^ref, :process, ^writer, :simulated_writer_crash}

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :orphaned}},
        Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])
      )
    end)

    assert :ok = ArtifactOutbox.recover(context.journal, context.state_dir)
    assert :error = Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])
  end

  test "artifact recovery child reconciles at startup and retries durable ACK cleanup", context do
    attrs = artifact_attrs("90000000-0000-0000-0000-000000000006")
    assert {:ok, manifest} = ArtifactOutbox.put(context.journal, context.state_dir, attrs, "done")
    {:ok, entry} = Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    assert :ok =
             Journal.put(context.journal, :artifact_outbox, attrs["artifact_id"], %{
               entry
               | status: :acked
             })

    {:ok, fail_sync} = Agent.start_link(fn -> true end)

    directory_sync = fn _directory ->
      if Agent.get(fail_sync, & &1), do: {:error, :disk_full}, else: :ok
    end

    {:ok, recovery} =
      ArtifactRecovery.start_link(
        name: nil,
        journal: context.journal,
        state_dir: context.state_dir,
        interval_ms: 60_000,
        directory_sync: directory_sync
      )

    refute File.exists?(ArtifactStore.path(context.state_dir, attrs["artifact_id"]))

    assert {:ok, %{status: :acked, manifest: ^manifest}} =
             Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"])

    Agent.update(fail_sync, fn _failed -> false end)
    send(recovery, :recover)

    assert_eventually(fn ->
      Journal.get(context.journal, :artifact_outbox, attrs["artifact_id"]) == :error
    end)

    GenServer.stop(recovery)
    Agent.stop(fail_sync)
  end

  test "artifact recovery removes stale identifiable temp and untracked final files", context do
    artifact_dir = Path.join(context.state_dir, "artifacts")
    :ok = File.mkdir_p(artifact_dir)
    untracked = ArtifactStore.path(context.state_dir, "untracked-artifact")
    temporary = untracked <> ".123.tmp"
    :ok = File.write(untracked, "untracked")
    :ok = File.write(temporary, "temporary")

    assert :ok = ArtifactOutbox.recover(context.journal, context.state_dir, stale_after_ms: 0)
    refute File.exists?(untracked)
    refute File.exists?(temporary)
  end

  defp artifact_attrs(artifact_id) do
    %{
      "artifact_id" => artifact_id,
      "job_id" => "99999999-9999-9999-9999-999999999999",
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "metadata" => %{}
    }
  end

  defp unique_journal_name do
    String.to_atom("browser_agent_journal_#{System.unique_integer([:positive])}")
  end

  defp assert_eventually(assertion, attempts \\ 20)

  defp assert_eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(assertion, attempts - 1)
    end
  end

  defp assert_eventually(_assertion, 0), do: flunk("condition did not become true")

  defp request(request_id, idempotency_key, operation, payload) do
    %RPCRequest{
      protocol_version: 1,
      request_id: request_id,
      capability: "browser.control",
      capability_version: 1,
      operation: operation,
      idempotency_key: idempotency_key,
      deadline_at: "2026-09-05T00:00:00Z",
      payload: payload
    }
  end
end
