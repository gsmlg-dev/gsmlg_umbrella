defmodule GSMLG.BrowserAgent.JournalRetentionTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Journal, ProfileLeaseServer, SafeBrowser, SessionSupervisor, Settings}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])

    %{
      path: Path.join(tmp_dir, "retention.dets"),
      dets_name: String.to_atom("retention_journal_#{suffix}"),
      registry_name: String.to_atom("retention_registry_#{suffix}"),
      runner_supervisor_name: String.to_atom("retention_runners_#{suffix}"),
      cdp_supervisor_name: String.to_atom("retention_cdp_#{suffix}"),
      tmp_dir: tmp_dir
    }
  end

  test "count retention prunes only terminal actions and sessions", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_terminal_max_records: 2)

    for {id, status, retryable} <- [
          {"unknown", :outcome_unknown, false},
          {"executing", :executing, false},
          {"retryable", :failed, true}
        ] do
      put_action(journal, id, status, retryable)
    end

    for {id, status} <- [
          {"terminal-a", :completed},
          {"terminal-b", :rejected},
          {"terminal-c", :failed}
        ] do
      put_action(journal, id, status, false)
      Agent.update(clock, &(&1 + 1))
    end

    assert :error = Journal.get(journal, :pending_action, {"session-1", "terminal-a"})

    assert {:ok, %{status: :rejected}} =
             Journal.get(journal, :pending_action, {"session-1", "terminal-b"})

    assert {:ok, %{status: :failed, retryable: false}} =
             Journal.get(journal, :pending_action, {"session-1", "terminal-c"})

    assert {:ok, %{status: :outcome_unknown}} =
             Journal.get(journal, :pending_action, {"session-1", "unknown"})

    assert {:ok, %{status: :executing}} =
             Journal.get(journal, :pending_action, {"session-1", "executing"})

    assert {:ok, %{status: :failed, retryable: true}} =
             Journal.get(journal, :pending_action, {"session-1", "retryable"})

    for {id, status, close_uncertain} <- [
          {"orphaned", :orphaned, false},
          {"uncertain", :failed, true},
          {"terminal-a", :closed, false},
          {"terminal-b", :failed, false},
          {"terminal-c", :closed, false}
        ] do
      put_session(journal, id, status, close_uncertain)
      Agent.update(clock, &(&1 + 1))
    end

    assert :error = Journal.get(journal, :browser_session, "terminal-a")
    assert {:ok, %{status: :failed}} = Journal.get(journal, :browser_session, "terminal-b")
    assert {:ok, %{status: :closed}} = Journal.get(journal, :browser_session, "terminal-c")
    assert {:ok, %{status: :orphaned}} = Journal.get(journal, :browser_session, "orphaned")

    assert {:ok, %{status: :failed, close_uncertain: true}} =
             Journal.get(journal, :browser_session, "uncertain")

    stop_journal(journal, context.dets_name)
  end

  test "byte retention never deletes unresolved records", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    journal =
      start_journal(context, clock,
        journal_terminal_max_age_ms: 100,
        journal_terminal_max_bytes: 1
      )

    put_action(journal, "terminal", :completed, false)
    put_action(journal, "unknown", :outcome_unknown, false)

    assert :error = Journal.get(journal, :pending_action, {"session-1", "terminal"})

    assert {:ok, %{status: :outcome_unknown}} =
             Journal.get(journal, :pending_action, {"session-1", "unknown"})

    stop_journal(journal, context.dets_name)
  end

  test "reserves terminal result capacity before an action can execute", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    journal =
      start_journal(context, clock,
        journal_terminal_max_records: 1,
        journal_terminal_max_bytes: 1_024
      )

    put_action(journal, "old-terminal", :completed, false)

    reserved = %{
      action_id: "reserved",
      session_id: "session-1",
      fingerprint: "fingerprint-reserved",
      status: :journaled,
      retryable: false,
      history: [:received, :journaled],
      retention_reserved_bytes: 512
    }

    assert :ok = Journal.put(journal, :pending_action, {"session-1", "reserved"}, reserved)
    assert :error = Journal.get(journal, :pending_action, {"session-1", "old-terminal"})

    second = %{reserved | action_id: "second", fingerprint: "fingerprint-second"}

    assert {:error, :journal_capacity_exceeded} =
             Journal.put(journal, :pending_action, {"session-1", "second"}, second)

    completed =
      Map.merge(reserved, %{
        status: :completed,
        history: [:received, :journaled, :validating, :executing, :verifying, :completed],
        result: %{"ok" => true}
      })

    assert :ok = Journal.put(journal, :pending_action, {"session-1", "reserved"}, completed)
    assert :ok = Journal.put(journal, :pending_action, {"session-1", "reserved"}, completed)
    assert {:ok, ^completed} = Journal.get(journal, :pending_action, {"session-1", "reserved"})

    stop_journal(journal, context.dets_name)
  end

  test "rejects an action reservation larger than the replay byte budget", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_terminal_max_bytes: 64)

    entry = %{
      action_id: "too-large",
      session_id: "session-1",
      fingerprint: "fingerprint-too-large",
      status: :journaled,
      retryable: false,
      history: [:received, :journaled],
      retention_reserved_bytes: 65
    }

    assert {:error, :journal_capacity_exceeded} =
             Journal.put(journal, :pending_action, {"session-1", "too-large"}, entry)

    assert :error = Journal.get(journal, :pending_action, {"session-1", "too-large"})
    stop_journal(journal, context.dets_name)
  end

  test "DETS reuses pruned terminal storage across several retention windows", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    opts = [
      journal_terminal_max_records: 8,
      journal_terminal_max_bytes: 131_072,
      sync: fn _table -> :ok end
    ]

    journal = start_journal(context, clock, opts)
    write_terminal_range(journal, clock, 1..80)
    assert :ok = :dets.sync(context.dets_name)
    stop_journal(journal, context.dets_name)
    first_size = File.stat!(context.path).size

    reopened = start_journal(context, clock, opts)
    write_terminal_range(reopened, clock, 81..400)
    assert :ok = :dets.sync(context.dets_name)
    stop_journal(reopened, context.dets_name)
    final_size = File.stat!(context.path).size

    assert final_size <= max(first_size * 4, 1_048_576)
  end

  test "terminal transitions use the incremental index and a single durable sync", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    journal =
      start_journal(context, clock,
        journal_terminal_max_records: 1,
        sync: fn table ->
          send(test_pid, :journal_sync)
          :dets.sync(table)
        end
      )

    put_action(journal, "first", :completed, false)
    flush_sync_messages()

    :erlang.trace_pattern({:dets, :select, 3}, true, [])
    :erlang.trace_pattern({:dets, :foldl, 3}, true, [])
    :erlang.trace(journal, true, [:call, {:tracer, test_pid}])

    on_exit(fn ->
      if Process.alive?(journal), do: :erlang.trace(journal, false, [:call])
      :erlang.trace_pattern({:dets, :select, 3}, false, [])
      :erlang.trace_pattern({:dets, :foldl, 3}, false, [])
    end)

    put_action(journal, "second", :completed, false)
    trace_ref = :erlang.trace_delivered(journal)
    trace_calls = receive_trace_calls(journal, trace_ref, [])

    refute Enum.any?(trace_calls, &match?({:dets, :select, _arguments}, &1))
    refute Enum.any?(trace_calls, &match?({:dets, :foldl, _arguments}, &1))
    assert_receive :journal_sync
    refute_receive :journal_sync

    stop_journal(journal, context.dets_name)
  end

  test "age retention removes expired terminal records on reopen", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    journal =
      start_journal(context, clock,
        journal_terminal_max_age_ms: 100,
        journal_terminal_max_bytes: 1_048_576
      )

    put_action(journal, "aged", :completed, false)
    put_action(journal, "unknown", :outcome_unknown, false)
    stop_journal(journal, context.dets_name)

    {:ok, aged_clock} = Agent.start_link(fn -> 1_000 end)

    aged =
      start_journal(context, aged_clock,
        journal_terminal_max_age_ms: 100,
        journal_terminal_max_bytes: 1_048_576
      )

    assert :error = Journal.get(aged, :pending_action, {"session-1", "aged"})

    assert {:ok, %{status: :outcome_unknown}} =
             Journal.get(aged, :pending_action, {"session-1", "unknown"})

    stop_journal(aged, context.dets_name)
  end

  test "bounded age pruning hides any expired terminal records left for later cleanup", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    journal =
      start_journal(context, clock,
        journal_terminal_max_age_ms: 100,
        sync: fn _table -> :ok end
      )

    for id <- 1..65 do
      put_action(journal, "aged-#{id}", :completed, false)
      put_session(journal, "aged-#{id}", :closed, false)
    end

    Agent.update(clock, fn _now -> 1_000 end)
    put_action(journal, "fresh", :completed, false)
    put_session(journal, "fresh", :closed, false)

    for id <- 1..65 do
      assert :error = Journal.get(journal, :pending_action, {"session-1", "aged-#{id}"})
      assert :error = Journal.get(journal, :browser_session, "aged-#{id}")
    end

    assert [{{"session-1", "fresh"}, %{status: :completed}}] =
             Enum.map(Journal.list(journal, :pending_action), fn {key, value} ->
               {key, Map.take(value, [:status])}
             end)

    assert [{"fresh", %{status: :closed}}] =
             Enum.map(Journal.list(journal, :browser_session), fn {key, value} ->
               {key, Map.take(value, [:status])}
             end)

    assert :error = Journal.browser_session_by_central_id(journal, "central-aged-65")

    assert {:ok, %{status: :closed}} =
             Journal.browser_session_by_central_id(journal, "central-fresh")

    stop_journal(journal, context.dets_name)
  end

  test "terminal session compaction drops observations without mutating live authority",
       context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock)
    large_observation = %{"semantic_tree" => [String.duplicate("x", 4_096)]}
    origin_policy = %{allowed_origins: MapSet.new(["https://gemini.google.com"])}

    terminal =
      session("terminal", :closed, false)
      |> Map.merge(%{observation: large_observation, origin_policy: origin_policy})

    live =
      session("live", :orphaned, false)
      |> Map.merge(%{observation: large_observation, origin_policy: origin_policy})

    assert :ok = Journal.put(journal, :browser_session, "terminal", terminal)
    assert :ok = Journal.put(journal, :browser_session, "live", live)

    assert {:ok, compacted} = Journal.get(journal, :browser_session, "terminal")
    assert compacted.observation == nil
    refute Map.has_key?(compacted, :origin_policy)
    assert compacted.central_session_id == "central-terminal"
    assert compacted.status == :closed

    assert {:ok, ^compacted} =
             Journal.browser_session_by_central_id(journal, "central-terminal")

    assert :error = Journal.browser_session_by_central_id(journal, "central-missing")

    assert {:ok, ^live} = Journal.get(journal, :browser_session, "live")
    stop_journal(journal, context.dets_name)
  end

  test "terminal-looking sessions with durable lease authority are never compacted or pruned",
       context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)

    journal =
      start_journal(context, clock,
        journal_terminal_max_records: 1,
        journal_terminal_max_bytes: 1
      )

    authoritative =
      session("authoritative", :closed, false)
      |> Map.put(:observation, %{"semantic_tree" => [String.duplicate("x", 4_096)]})

    assert :ok =
             Journal.put(journal, :profile_lease, "profile-authoritative", %{
               owner_id: "authoritative",
               suspended: nil
             })

    assert :ok =
             Journal.put(journal, :browser_session, "authoritative", authoritative)

    assert {:ok, ^authoritative} =
             Journal.get(journal, :browser_session, "authoritative")

    stop_journal(journal, context.dets_name)
  end

  test "lease release incrementally makes its closed session a retention candidate", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_terminal_max_records: 1)

    assert :ok =
             Journal.put(journal, :profile_lease, "profile-authoritative", %{
               owner_id: "authoritative",
               suspended: nil
             })

    put_session(journal, "authoritative", :closed, false)
    Agent.update(clock, &(&1 + 1))
    put_session(journal, "terminal", :closed, false)

    assert :ok = Journal.delete(journal, :profile_lease, "profile-authoritative")
    Agent.update(clock, &(&1 + 1))
    put_session(journal, "new-terminal", :closed, false)

    assert :error = Journal.get(journal, :browser_session, "authoritative")
    assert :error = Journal.get(journal, :browser_session, "terminal")
    assert {:ok, %{status: :closed}} = Journal.get(journal, :browser_session, "new-terminal")

    stop_journal(journal, context.dets_name)
  end

  test "lease acquisition incrementally protects its existing closed session", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_terminal_max_records: 2)

    put_session(journal, "protected", :closed, false)

    assert :ok =
             Journal.put(journal, :profile_lease, "profile-protected", %{
               owner_id: "protected",
               suspended: nil
             })

    Agent.update(clock, &(&1 + 1))
    put_session(journal, "terminal-a", :closed, false)
    Agent.update(clock, &(&1 + 1))
    put_session(journal, "terminal-b", :closed, false)

    assert {:ok, %{status: :closed}} = Journal.get(journal, :browser_session, "protected")
    assert {:ok, %{status: :closed}} = Journal.get(journal, :browser_session, "terminal-a")
    assert {:ok, %{status: :closed}} = Journal.get(journal, :browser_session, "terminal-b")

    stop_journal(journal, context.dets_name)
  end

  test "pending action recovery fails before partially scanning an oversized unresolved set",
       context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_recovery_scan_max_records: 1)

    put_action(journal, "first", :executing, false)
    put_action(journal, "second", :verifying, false)

    assert {:error, :recovery_scan_limit_exceeded} =
             SafeBrowser.recover_actions(journal, "session-1")

    assert {:ok, %{status: :executing}} =
             Journal.get(journal, :pending_action, {"session-1", "first"})

    assert {:ok, %{status: :verifying}} =
             Journal.get(journal, :pending_action, {"session-1", "second"})

    stop_journal(journal, context.dets_name)
  end

  test "session startup fails closed when the bounded recovery set is exceeded", context do
    {:ok, clock} = Agent.start_link(fn -> 0 end)
    journal = start_journal(context, clock, journal_recovery_scan_max_records: 1)

    assert :ok =
             Journal.put(
               journal,
               :browser_session,
               "session-a",
               session("session-a", :ready, false)
             )

    assert :ok =
             Journal.put(
               journal,
               :browser_session,
               "session-b",
               session("session-b", :ready, false)
             )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)
    settings = settings(context.tmp_dir, 2)

    {:ok, supervisor} =
      SessionSupervisor.start_link(
        name: nil,
        settings: settings,
        journal: journal,
        lease_server: leases,
        registry_name: context.registry_name,
        runner_supervisor_name: context.runner_supervisor_name,
        cdp_supervisor_name: context.cdp_supervisor_name
      )

    assert {:error, :recovery_scan_limit_exceeded} =
             SessionSupervisor.open(supervisor, %{
               "central_session_id" => "new-central",
               "profile_id" => "new-profile",
               "mode" => "automation",
               "authorized_origins" => ["https://gemini.google.com"],
               "ttl_ms" => 60_000,
               "permissions" => %{}
             })

    assert [] = DynamicSupervisor.which_children(context.runner_supervisor_name)

    Supervisor.stop(supervisor)
    GenServer.stop(leases)
    stop_journal(journal, context.dets_name)
  end

  defp start_journal(context, clock, opts \\ []) do
    defaults = [
      name: nil,
      path: context.path,
      dets_name: context.dets_name,
      clock_ms: fn -> Agent.get(clock, & &1) end,
      journal_terminal_max_records: 100,
      journal_terminal_max_age_ms: 86_400_000,
      journal_terminal_max_bytes: 1_048_576,
      journal_recovery_scan_max_records: 100
    ]

    {:ok, journal} = Journal.start_link(Keyword.merge(defaults, opts))
    journal
  end

  defp stop_journal(journal, dets_name) do
    if Process.alive?(journal), do: GenServer.stop(journal)
    _ = :dets.close(dets_name)
  end

  defp put_action(journal, id, status, retryable) do
    assert :ok =
             Journal.put(journal, :pending_action, {"session-1", id}, %{
               action_id: id,
               session_id: "session-1",
               fingerprint: "fingerprint-#{id}",
               status: status,
               retryable: retryable,
               history: [status],
               result: if(status == :completed, do: %{"payload" => String.duplicate("x", 64)})
             })
  end

  defp put_session(journal, id, status, close_uncertain) do
    assert :ok =
             Journal.put(
               journal,
               :browser_session,
               id,
               session(id, status, close_uncertain)
             )
  end

  defp write_terminal_range(journal, clock, range) do
    Enum.each(range, fn id ->
      assert :ok =
               Journal.put(journal, :pending_action, {"churn", Integer.to_string(id)}, %{
                 action_id: Integer.to_string(id),
                 session_id: "churn",
                 fingerprint: "fingerprint-#{id}",
                 status: :completed,
                 retryable: false,
                 history: [:completed],
                 result: %{"payload" => String.duplicate("x", 4_096)}
               })

      Agent.update(clock, &(&1 + 1))
    end)
  end

  defp flush_sync_messages do
    receive do
      :journal_sync -> flush_sync_messages()
    after
      0 -> :ok
    end
  end

  defp receive_trace_calls(journal, trace_ref, calls) do
    receive do
      {:trace, ^journal, :call, call} -> receive_trace_calls(journal, trace_ref, [call | calls])
      {:trace_delivered, ^journal, ^trace_ref} -> Enum.reverse(calls)
    after
      1_000 -> flunk("timed out waiting for Journal trace delivery")
    end
  end

  defp session(id, status, close_uncertain) do
    now = DateTime.from_unix!(0)

    %{
      central_session_id: "central-#{id}",
      remote_session_id: id,
      profile_id: "profile-#{id}",
      lease_id: nil,
      mode: :automation,
      status: status,
      authorized_origins: ["https://gemini.google.com"],
      permissions: %{download: false, screenshot: false},
      ttl_ms: 60_000,
      revision: 0,
      observation: nil,
      origin_policy: nil,
      created_at: now,
      updated_at: now,
      expires_at: DateTime.add(now, 60_000, :millisecond),
      close_uncertain: close_uncertain
    }
  end

  defp settings(state_dir, max_sessions) do
    Settings.load!(
      %{
        enabled: true,
        manager_url: "http://127.0.0.1:8080",
        manager_token_env: "IGNORED",
        state_dir: state_dir,
        max_concurrent_sessions: max_sessions,
        security: %{
          allowed_origins: ["https://gemini.google.com"],
          allowed_upload_origins: ["https://uploads.example.test"]
        }
      },
      manager_token: "secret"
    )
  end
end
