defmodule GSMLG.BrowserAgent.WorkflowLifecycleTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{ArtifactOutbox, Journal, WorkflowArtifacts, WorkflowSupervisor}

  @moduletag :tmp_dir
  @execution_id "00000000-0000-4000-8000-000000000001"
  @job_id "00000000-0000-4000-8000-000000000101"
  @session_id "00000000-0000-4000-8000-000000000201"

  defmodule FakeSession do
    def open_workflow(agent, params) do
      Agent.update(agent, &Map.update!(&1, :calls, fn calls -> calls ++ [{:open, params}] end))

      {:ok,
       %{
         "remote_session_id" => "00000000-0000-4000-8000-000000000201",
         "status" => "ready"
       }}
    end

    def observe(agent, session_id) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls -> calls ++ [{:observe, session_id}] end)
      )

      {:ok, %{kind: :chat, revision: 1, url: "https://gemini.google.com/app/conversation-1"}}
    end

    def act(agent, session_id, action) do
      Agent.get_and_update(agent, fn state ->
        reply =
          case {action["type"], state.screenshot_manifest} do
            {"screenshot", manifest} when is_map(manifest) ->
              {:ok, %{"status" => "ready", "output" => %{"artifact" => manifest}}}

            _other ->
              {:ok, %{"status" => "ready"}}
          end

        {reply, Map.update!(state, :calls, &(&1 ++ [{:act, session_id, action}]))}
      end)
    end

    def manual_handoff(agent, session_id, operator_id) do
      Agent.update(agent, fn state ->
        state
        |> Map.update!(:calls, &(&1 ++ [{:manual_handoff, session_id, operator_id}]))
        |> Map.put(:mode, :manual)
      end)

      {:ok, %{"status" => "waiting_human"}}
    end

    def resume_automation(agent, session_id) do
      Agent.update(agent, fn state ->
        state
        |> Map.update!(:calls, &(&1 ++ [{:resume_automation, session_id}]))
        |> Map.put(:mode, :automation)
      end)

      {:ok, %{"status" => "ready"}}
    end

    def close(agent, session_id) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls -> calls ++ [{:close, session_id}] end)
      )

      {:ok, %{"status" => "closed"}}
    end

    def reconcile(agent, session_id) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls -> calls ++ [{:reconcile, session_id}] end)
      )

      {:ok, %{"status" => "ready"}}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    dets = String.to_atom("workflow_lifecycle_#{System.unique_integer([:positive])}")
    registry = String.to_atom("workflow_registry_#{System.unique_integer([:positive])}")
    runners = String.to_atom("workflow_runners_#{System.unique_integer([:positive])}")

    {:ok, sessions} =
      Agent.start_link(fn -> %{calls: [], mode: :automation, screenshot_manifest: nil} end)

    {:ok, clock} = Agent.start_link(fn -> ~U[2026-09-06 00:00:00Z] end)

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "workflow-lifecycle.dets"),
        dets_name: dets
      )

    {:ok, supervisor} =
      WorkflowSupervisor.start_link(
        name: nil,
        journal: journal,
        session_api: FakeSession,
        session_supervisor: sessions,
        registry_name: registry,
        runner_supervisor_name: runners,
        max_children: 1,
        state_dir: tmp_dir,
        auto_run: false,
        id_generator: fn -> @execution_id end,
        generation_generator: fn -> "runner-generation" end,
        clock: fn -> Agent.get(clock, & &1) end
      )

    on_exit(fn ->
      safe_stop(supervisor, &Supervisor.stop/1)
      safe_stop(clock, &Agent.stop/1)
      safe_stop(journal, &GenServer.stop/1)
      _ = :dets.close(dets)
    end)

    %{
      journal: journal,
      supervisor: supervisor,
      sessions: sessions,
      clock: clock,
      tmp_dir: tmp_dir
    }
  end

  test "start is durably accepted and replayed; identities and output formats are strict", ctx do
    assert {:ok, accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert accepted["remote_execution_id"] == @execution_id
    assert accepted["central_job_id"] == @job_id
    assert accepted["remote_session_id"] == @session_id
    assert accepted["status"] == "running"

    assert {:ok, ^accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert Enum.count(Agent.get(ctx.sessions, & &1.calls), &match?({:open, _}, &1)) == 1

    assert [{:open, open_params}] =
             Enum.filter(Agent.get(ctx.sessions, & &1.calls), &match?({:open, _}, &1))

    assert open_params["mode"] == "workflow"
    assert open_params["remote_execution_id"] == @execution_id
    assert open_params["central_session_id"] == @execution_id
    assert open_params["artifact_job_id"] == @job_id
    assert open_params["required_profile_capabilities"] == ["gemini_authenticated"]

    invalid = Map.put(start_payload(), "output_formats", ["report.markdown", "raw_html"])

    assert {:error, :invalid_workflow_request} =
             WorkflowSupervisor.start(ctx.supervisor, invalid, request_meta())

    conflicting =
      put_in(start_payload(), ["input", "profile_id"], "attacker-selected-profile")

    assert {:error, :invalid_workflow_request} =
             WorkflowSupervisor.start(ctx.supervisor, conflicting, request_meta())

    assert {:error, :central_job_id_collision} =
             WorkflowSupervisor.start(
               ctx.supervisor,
               Map.put(start_payload(), "input", Map.put(deep_input(), "prompt", "different")),
               request_meta()
             )
  end

  test "status, cancel, and reconcile bind central and remote identities", ctx do
    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert {:ok, %{"status" => "running"}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)

    assert {:error, :workflow_identity_mismatch} =
             WorkflowSupervisor.status(ctx.supervisor, "wrong-job", @execution_id)

    assert {:error, :invalid_workflow_request} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, nil)

    assert {:ok, %{"remote_execution_id" => @execution_id}} =
             WorkflowSupervisor.reconcile(ctx.supervisor, @job_id, nil)

    assert {:ok, %{"status" => "cancelled"} = cancelled} =
             WorkflowSupervisor.cancel(ctx.supervisor, @job_id, @execution_id)

    assert {:ok, ^cancelled} =
             WorkflowSupervisor.cancel(ctx.supervisor, @job_id, @execution_id)

    assert [%{"event" => "workflow.cancelled"}] =
             Journal.event_unacked(ctx.journal, @execution_id)
             |> Enum.filter(&(&1["event"] == "workflow.cancelled"))

    unacked = Journal.event_unacked(ctx.journal, @execution_id)
    last_sequence = unacked |> List.last() |> Map.fetch!("sequence")

    Enum.each(unacked, fn event ->
      assert :ok = Journal.mark_event_emitted(ctx.journal, @execution_id, event["sequence"])
    end)

    assert :ok = Journal.ack_events(ctx.journal, @execution_id, last_sequence)

    assert {:ok, %{"last_sequence" => ^last_sequence}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)
  end

  test "intervention hands automation to the authenticated actor and resume reacquires then observes",
       ctx do
    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert {:ok, %{"status" => "waiting_human", "intervention" => intervention}} =
             WorkflowSupervisor.intervene(
               ctx.supervisor,
               @job_id,
               @execution_id,
               :plan_approval_required
             )

    assert intervention["reason_code"] == "plan_approval_required"
    assert intervention["reason"] == "plan_approval_required"
    assert intervention["operator_id"] == "actor-1"
    assert intervention["instructions"] =~ "approve the research plan"

    assert {:error, :operator_identity_required} =
             WorkflowSupervisor.resume(ctx.supervisor, @job_id, @execution_id, "")

    assert {:error, :operator_identity_mismatch} =
             WorkflowSupervisor.resume(ctx.supervisor, @job_id, @execution_id, "actor-2")

    assert {:ok, %{"status" => "running"}} =
             WorkflowSupervisor.resume(ctx.supervisor, @job_id, @execution_id, "actor-1")

    calls = Agent.get(ctx.sessions, & &1.calls)
    assert {:manual_handoff, @session_id, "actor-1"} in calls

    resume_index = Enum.find_index(calls, &match?({:resume_automation, @session_id}, &1))
    observe_index = Enum.find_index(calls, &match?({:observe, @session_id}, &1))
    assert resume_index < observe_index
  end

  test "expired starts are rejected before claiming or launching", ctx do
    expired = Map.put(request_meta(), :deadline_at, "2026-09-05T23:59:59Z")

    assert {:error, :workflow_deadline_exceeded} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), expired)

    assert [] = Journal.workflow_list(ctx.journal)
    assert [] = Agent.get(ctx.sessions, & &1.calls)
  end

  test "deadline expiry blocks resume before automation is reacquired", ctx do
    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert {:ok, %{"status" => "waiting_human"}} =
             WorkflowSupervisor.intervene(
               ctx.supervisor,
               @job_id,
               @execution_id,
               :plan_approval_required
             )

    Agent.update(ctx.clock, fn _now -> ~U[2026-09-06 01:00:01Z] end)

    assert {:error, :workflow_deadline_exceeded} =
             WorkflowSupervisor.resume(ctx.supervisor, @job_id, @execution_id, "actor-1")

    assert {:ok, %{"status" => "failed"}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)

    refute Enum.any?(Agent.get(ctx.sessions, & &1.calls), &match?({:resume_automation, _}, &1))
  end

  test "workflow telemetry reports bounded phase duration, intervention, and failure codes",
       ctx do
    {:ok, _started} = Application.ensure_all_started(:telemetry)
    handler_id = "workflow-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler_id,
        [
          [:gsmlg, :browser, :workflow, :transition],
          [:gsmlg, :browser, :intervention, :required]
        ],
        &__MODULE__.handle_workflow_telemetry/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert_receive {:workflow_telemetry, [:gsmlg, :browser, :workflow, :transition],
                    %{count: 1, duration_ms: duration_ms},
                    %{
                      remote_execution_id: @execution_id,
                      central_job_id: @job_id,
                      workflow: "gemini.deep_research/v1",
                      phase: "acquire_profile",
                      status: "running"
                    }}

    assert is_integer(duration_ms) and duration_ms >= 0

    assert {:ok, %{"status" => "waiting_human"}} =
             WorkflowSupervisor.intervene(
               ctx.supervisor,
               @job_id,
               @execution_id,
               :plan_approval_required
             )

    assert_receive {:workflow_telemetry, [:gsmlg, :browser, :intervention, :required],
                    %{count: 1},
                    %{
                      remote_execution_id: @execution_id,
                      central_job_id: @job_id,
                      workflow: "gemini.deep_research/v1",
                      phase: "inspect_auth",
                      intervention_reason: "plan_approval_required"
                    }}

    Agent.update(ctx.clock, fn _now -> ~U[2026-09-06 01:00:01Z] end)

    assert {:error, :workflow_deadline_exceeded} =
             WorkflowSupervisor.resume(ctx.supervisor, @job_id, @execution_id, "actor-1")

    assert_receive {:workflow_telemetry, [:gsmlg, :browser, :workflow, :transition],
                    %{count: 1, duration_ms: failed_duration_ms},
                    %{
                      status: "failed",
                      failure_code: "workflow_deadline_exceeded",
                      phase: "inspect_auth"
                    } = failure_metadata}

    assert failed_duration_ms >= 3_600_000

    encoded = JSON.encode!(failure_metadata)
    refute encoded =~ start_payload()["input"]["prompt"]
    refute encoded =~ "gemini.google.com"
  end

  test "status exposes only an authorized Gemini chat URL and runner restart reloads its checkpoint",
       ctx do
    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    assert {:ok, %{"phase" => "open_chat", "chat_url" => chat_url}} =
             WorkflowSupervisor.step(ctx.supervisor, @job_id, @execution_id)

    assert chat_url == "https://gemini.google.com/app/conversation-1"

    first_runner = WorkflowSupervisor.runner(ctx.supervisor, @execution_id)
    Process.exit(first_runner, :kill)

    assert eventually(fn ->
             case WorkflowSupervisor.runner(ctx.supervisor, @execution_id) do
               pid when is_pid(pid) -> pid != first_runner
               _missing -> false
             end
           end)

    assert {:ok, %{"phase" => "open_chat", "chat_url" => ^chat_url}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)

    assert Enum.count(Agent.get(ctx.sessions, & &1.calls), &match?({:open, _}, &1)) == 1

    restarted = WorkflowSupervisor.runner(ctx.supervisor, @execution_id)

    :sys.replace_state(restarted, fn state ->
      checkpoint = %{state.checkpoint | last_observation: %{url: "https://evil.example/chat"}}
      %{state | checkpoint: checkpoint}
    end)

    assert {:ok, %{"chat_url" => nil}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)

    :sys.replace_state(restarted, fn state ->
      checkpoint = %{
        state.checkpoint
        | last_observation: %{url: "https://gemini.google.com:444/app/private"}
      }

      %{state | checkpoint: checkpoint}
    end)

    assert {:ok, %{"chat_url" => nil}} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)
  end

  test "requested screenshots are captured as a safe action before durable completion", ctx do
    payload =
      Map.put(start_payload(), "output_formats", [
        "report.markdown",
        "report.json",
        "sources.json",
        "screenshot.png"
      ])

    assert {:ok, _accepted} = WorkflowSupervisor.start(ctx.supervisor, payload, request_meta())

    screenshot_id = WorkflowArtifacts.artifact_id(@execution_id, "screenshot.png")

    assert {:ok, screenshot_manifest} =
             ArtifactOutbox.put(
               ctx.journal,
               ctx.tmp_dir,
               %{
                 "artifact_id" => screenshot_id,
                 "job_id" => @job_id,
                 "kind" => "screenshot.png",
                 "mime" => "image/png",
                 "filename" => "report.png",
                 "metadata" => %{"remote_execution_id" => @execution_id}
               },
               "png"
             )

    Agent.update(ctx.sessions, &Map.put(&1, :screenshot_manifest, screenshot_manifest))

    result = %{
      markdown: "# Summary\nExample\n# Evidence\nSource",
      html: "<h1>Summary</h1>",
      structured: %{"summary" => "Example"},
      sources: [%{"title" => "Source", "url" => "https://example.com/source"}]
    }

    runner = WorkflowSupervisor.runner(ctx.supervisor, @execution_id)

    :sys.replace_state(runner, fn state ->
      workflow_state = %{
        state.checkpoint.workflow_state
        | phase: :produce_artifacts,
          result: result
      }

      checkpoint = %{state.checkpoint | phase: :produce_artifacts, workflow_state: workflow_state}
      %{state | checkpoint: checkpoint}
    end)

    assert {:ok, %{"status" => "completed", "artifacts" => artifacts, "result" => wire_result}} =
             WorkflowSupervisor.step(ctx.supervisor, @job_id, @execution_id)

    assert Enum.any?(artifacts, &(&1["artifact_id"] == screenshot_id))
    assert wire_result["available"] == true
    assert screenshot_id in wire_result["artifact_ids"]
    assert wire_result["content_hashes"]["screenshot.png"] == screenshot_manifest["sha256"]

    encoded_result = JSON.encode!(wire_result)
    refute encoded_result =~ "Example"
    refute encoded_result =~ "https://example.com/source"
    assert byte_size(encoded_result) <= 16_384

    assert Enum.any?(Agent.get(ctx.sessions, & &1.calls), fn
             {:act, @session_id, %{"type" => "screenshot"}} -> true
             _other -> false
           end)

    assert {:ok, %{status: :completed}} = Journal.workflow_get(ctx.journal, @execution_id)
  end

  test "status summarizes an oversized durable result without crossing the wire ceiling", ctx do
    assert {:ok, _accepted} =
             WorkflowSupervisor.start(ctx.supervisor, start_payload(), request_meta())

    runner = WorkflowSupervisor.runner(ctx.supervisor, @execution_id)
    private_report = String.duplicate("private report body ", 20_000)

    :sys.replace_state(runner, fn state ->
      checkpoint = %{
        state.checkpoint
        | status: :completed,
          phase: :completed,
          result: %{markdown: private_report}
      }

      %{state | checkpoint: checkpoint}
    end)

    assert {:ok, %{"result" => %{"available" => true}} = snapshot} =
             WorkflowSupervisor.status(ctx.supervisor, @job_id, @execution_id)

    encoded = JSON.encode!(snapshot)
    refute encoded =~ "private report body"
    assert byte_size(encoded) <= 131_072
  end

  defp start_payload do
    %{
      "central_job_id" => @job_id,
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "profile_id" => "profile-1",
      "input" => deep_input(),
      "output_formats" => ["report.markdown", "report.html", "report.json", "sources.json"],
      "requested_by_actor_id" => "actor-1"
    }
  end

  def handle_workflow_telemetry(event, measurements, metadata, pid),
    do: send(pid, {:workflow_telemetry, event, measurements, metadata})

  defp deep_input do
    %{
      "prompt" => "Research a sanitized topic",
      "output_locale" => "en-US",
      "research_scope" => "web",
      "required_sections" => ["Summary", "Evidence"],
      "auto_approve_plan" => true
    }
  end

  defp request_meta do
    %{
      idempotency_key: "workflow-idempotency-1",
      deadline_at: "2026-09-06T01:00:00Z"
    }
  end

  defp safe_stop(pid, stop) do
    if Process.alive?(pid), do: stop.(pid)
  catch
    :exit, _reason -> :ok
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
