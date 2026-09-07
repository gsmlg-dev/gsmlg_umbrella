defmodule GSMLG.BrowserAgent.ProfileLeaseTest do
  use ExUnit.Case, async: false

  alias GSMLG.BrowserAgent.{Journal, ProfileLease, ProfileLeaseServer}

  @moduletag :tmp_dir

  @now ~U[2026-09-04 00:00:00Z]

  test "pure transitions enforce exclusive automation/manual leases and atomic handoff" do
    assert {:ok, automation} =
             ProfileLease.acquire(nil,
               profile_id: "profile-1",
               lease_id: "automation-1",
               owner_type: :automation,
               owner_id: "job-1",
               mode: :workflow,
               now: @now,
               ttl_ms: 60_000
             )

    assert {:error, :profile_busy} =
             ProfileLease.acquire(automation,
               profile_id: "profile-1",
               lease_id: "manual-conflict",
               owner_type: :manual,
               owner_id: "operator-1",
               mode: :manual,
               now: @now,
               ttl_ms: 60_000
             )

    assert {:ok, manual} =
             ProfileLease.manual_handoff(automation,
               lease_id: "manual-1",
               owner_id: "operator-1",
               now: @now,
               ttl_ms: 60_000
             )

    assert manual.owner_type == :manual
    assert manual.suspended.owner_id == "job-1"

    assert {:ok, resumed} =
             ProfileLease.resume(manual,
               lease_id: "automation-2",
               now: DateTime.add(@now, 10, :second),
               ttl_ms: 60_000
             )

    assert %{owner_type: :automation, owner_id: "job-1", lease_id: "automation-2"} = resumed
    assert resumed.suspended == nil
  end

  test "expiry requires explicit reconcile confirmation before reclaim" do
    assert {:ok, lease} =
             ProfileLease.acquire(nil,
               profile_id: "profile-1",
               lease_id: "automation-1",
               owner_type: :automation,
               owner_id: "job-1",
               mode: :workflow,
               now: @now,
               ttl_ms: 1_000
             )

    expired_at = DateTime.add(@now, 2, :second)

    assert {:error, :profile_busy} =
             ProfileLease.acquire(lease,
               profile_id: "profile-1",
               lease_id: "new",
               owner_type: :automation,
               owner_id: "job-2",
               mode: :workflow,
               now: expired_at,
               ttl_ms: 1_000
             )

    assert {:ok, ^lease} = ProfileLease.reconcile(lease, execution_active?: true, now: expired_at)
    assert {:ok, nil} = ProfileLease.reconcile(lease, execution_active?: false, now: expired_at)
  end

  test "serialized server persists recovery and grants only one concurrent caller", %{
    tmp_dir: tmp_dir
  } do
    path = Path.join(tmp_dir, "lease-journal.dets")
    dets_name = :browser_agent_lease_journal_test
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets_name)
    {:ok, server} = ProfileLeaseServer.start_link(name: nil, journal: journal)

    callers = [
      [lease_id: "lease-1", owner_id: "job-1"],
      [lease_id: "lease-2", owner_id: "job-2"]
    ]

    results =
      callers
      |> Task.async_stream(
        fn caller ->
          ProfileLeaseServer.acquire(server, "profile-1", :automation, caller[:owner_id],
            lease_id: caller[:lease_id],
            mode: :workflow,
            now: @now,
            ttl_ms: 60_000
          )
        end,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert 1 == Enum.count(results, &match?({:ok, %ProfileLease{}}, &1))
    assert 1 == Enum.count(results, &match?({:error, :profile_busy}, &1))

    assert {:ok, lease} = ProfileLeaseServer.get(server, "profile-1")

    assert {:ok, renewed} =
             ProfileLeaseServer.heartbeat(server, "profile-1", lease.lease_id,
               now: DateTime.add(@now, 5, :second),
               ttl_ms: 60_000
             )

    assert DateTime.compare(renewed.expires_at, lease.expires_at) == :gt

    assert {:ok, manual} =
             ProfileLeaseServer.manual_handoff(
               server,
               "profile-1",
               renewed.lease_id,
               "operator-1",
               lease_id: "manual-1",
               now: DateTime.add(@now, 6, :second),
               ttl_ms: 60_000
             )

    GenServer.stop(server)

    {:ok, reopened} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    assert {:ok, ^manual} = ProfileLeaseServer.get(reopened, "profile-1")

    assert {:ok, resumed} =
             ProfileLeaseServer.resume(reopened, "profile-1", manual.lease_id,
               lease_id: "automation-resumed",
               now: DateTime.add(@now, 7, :second),
               ttl_ms: 1_000
             )

    assert %{owner_type: :automation, owner_id: "job-1"} = resumed

    assert {:ok, ^resumed} =
             ProfileLeaseServer.reconcile(reopened, "profile-1", true,
               now: DateTime.add(@now, 9, :second)
             )

    assert {:ok, nil} =
             ProfileLeaseServer.reconcile(reopened, "profile-1", false,
               now: DateTime.add(@now, 9, :second)
             )

    assert :error = ProfileLeaseServer.get(reopened, "profile-1")

    assert {:ok, final_lease} =
             ProfileLeaseServer.acquire(reopened, "profile-1", :automation, "job-final",
               lease_id: "lease-final",
               mode: :workflow,
               now: DateTime.add(@now, 10, :second),
               ttl_ms: 60_000
             )

    assert {:error, :lease_conflict} =
             ProfileLeaseServer.release(reopened, "profile-1", "not-the-owner")

    assert :ok = ProfileLeaseServer.release(reopened, "profile-1", final_lease.lease_id)
    assert :error = ProfileLeaseServer.get(reopened, "profile-1")

    GenServer.stop(reopened)
    GenServer.stop(journal)
    _ = :dets.close(dets_name)
  end

  test "an unleased profile mutation serializes against lease acquisition", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "mutation-journal.dets")
    dets_name = :browser_agent_mutation_journal_test
    {:ok, journal} = Journal.start_link(name: nil, path: path, dets_name: dets_name)
    {:ok, server} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    test_pid = self()

    mutation =
      Task.async(fn ->
        ProfileLeaseServer.run_unleased(server, "profile-1", fn ->
          send(test_pid, {:mutation_started, self()})
          receive do: (:continue -> :mutation_complete)
        end)
      end)

    assert_receive {:mutation_started, mutation_owner}

    acquisition =
      Task.async(fn ->
        ProfileLeaseServer.acquire(server, "profile-1", :automation, "job-1",
          lease_id: "lease-1",
          now: @now,
          ttl_ms: 60_000
        )
      end)

    assert Task.yield(acquisition, 50) == nil
    send(mutation_owner, :continue)
    assert Task.await(mutation) == :mutation_complete
    assert {:ok, %ProfileLease{lease_id: "lease-1"}} = Task.await(acquisition)

    GenServer.stop(server)
    GenServer.stop(journal)
    _ = :dets.close(dets_name)
  end
end
