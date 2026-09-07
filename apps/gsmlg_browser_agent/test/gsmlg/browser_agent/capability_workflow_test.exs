defmodule GSMLG.BrowserAgent.CapabilityWorkflowTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Capability, Journal, Settings}
  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.{EventAck, RPCRequest}

  @moduletag :tmp_dir
  @execution_id "00000000-0000-4000-8000-000000000055"
  @job_id "00000000-0000-4000-8000-000000000155"

  defmodule WorkflowAPI do
    def start(agent, payload, meta) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls -> [{:start, payload, meta} | calls] end)
      )

      {:ok,
       %{
         "central_job_id" => payload["central_job_id"],
         "remote_execution_id" => "00000000-0000-4000-8000-000000000055",
         "status" => "running"
       }}
    end

    def status(_agent, "oversized", remote_id) do
      {:ok,
       %{
         "central_job_id" => "oversized",
         "remote_execution_id" => remote_id,
         "result" => String.duplicate("private result", 20_000)
       }}
    end

    def status(_agent, central_id, remote_id),
      do: {:ok, %{"central_job_id" => central_id, "remote_execution_id" => remote_id}}

    def cancel(_agent, central_id, remote_id), do: status(nil, central_id, remote_id)
    def resume(_agent, central_id, remote_id, _operator), do: status(nil, central_id, remote_id)
    def reconcile(_agent, central_id, remote_id), do: status(nil, central_id, remote_id)
  end

  defmodule SessionAPI do
    def manual_acquire(agent, session_id, operator_id) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls -> [{:acquire, session_id, operator_id} | calls] end)
      )

      {:ok,
       %{
         "remote_session_id" => session_id,
         "profile_id" => "profile-1",
         "lease_id" => "manual-lease",
         "lease_owner_type" => "manual",
         "lease_owner_id" => operator_id,
         "status" => "waiting_human"
       }}
    end

    def manual_release(agent, session_id, lease_id, operator_id) do
      Agent.update(
        agent,
        &Map.update!(&1, :calls, fn calls ->
          [{:release, session_id, lease_id, operator_id} | calls]
        end)
      )

      {:ok,
       %{
         "remote_session_id" => session_id,
         "profile_id" => "profile-1",
         "lease_id" => nil,
         "lease_owner_type" => "released",
         "lease_owner_id" => operator_id,
         "status" => "waiting_human"
       }}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    suffix = System.unique_integer([:positive])
    dets = String.to_atom("capability_workflow_#{suffix}")

    {:ok, journal} =
      Journal.start_link(name: nil, path: Path.join(tmp_dir, "rpc.dets"), dets_name: dets)

    {:ok, registry} = CapabilityRegistry.start_link(name: nil)
    {:ok, calls} = Agent.start_link(fn -> %{calls: []} end)

    settings =
      Settings.load!(
        %{
          enabled: true,
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: tmp_dir,
          security: %{allowed_upload_origins: ["https://uploads.example.test"]}
        },
        manager_token: "secret"
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        settings: settings,
        registry: registry,
        journal: journal,
        workflow_api: WorkflowAPI,
        workflow_supervisor: calls,
        session_api: SessionAPI,
        session_supervisor: calls
      )

    on_exit(fn ->
      for pid <- [capability, calls, registry, journal],
          Process.alive?(pid),
          do: GenServer.stop(pid)

      _ = :dets.close(dets)
    end)

    %{capability: capability, calls: calls, journal: journal, settings: settings}
  end

  test "workflow.start returns the accepted envelope contract and preserves request metadata",
       ctx do
    payload = %{
      "central_job_id" => @job_id,
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "profile_id" => "profile-1",
      "input" => %{},
      "output_formats" => ["report.markdown", "report.json", "sources.json"],
      "requested_by_actor_id" => "actor-1"
    }

    request = rpc("workflow.start", payload, 1)

    assert {:accepted, @execution_id} = GenServer.call(ctx.capability, {:rpc, request})
    assert {:accepted, @execution_id} = GenServer.call(ctx.capability, {:rpc, request})

    assert [{:start, ^payload, meta}] = Agent.get(ctx.calls, & &1.calls)
    assert meta.idempotency_key == request.idempotency_key
    assert meta.deadline_at == request.deadline_at
  end

  test "manual acquire/release operations are exact, identity carrying, and deduplicated", ctx do
    acquire =
      rpc(
        "session.manual_acquire",
        %{"session_id" => "session-1", "operator_id" => "actor-1"},
        2
      )

    assert {:ok, %{"lease_owner_type" => "manual", "lease_id" => "manual-lease"}} =
             GenServer.call(ctx.capability, {:rpc, acquire})

    assert {:ok, %{"lease_owner_type" => "manual"}} =
             GenServer.call(ctx.capability, {:rpc, acquire})

    release =
      rpc(
        "session.manual_release",
        %{
          "session_id" => "session-1",
          "lease_id" => "manual-lease",
          "operator_id" => "actor-1"
        },
        3
      )

    assert {:ok, %{"lease_owner_type" => "released", "lease_id" => nil}} =
             GenServer.call(ctx.capability, {:rpc, release})

    assert {:error, %{code: "invalid_operation_payload"}} =
             GenServer.call(
               ctx.capability,
               {:rpc,
                rpc(
                  "session.manual_release",
                  %{"session_id" => "session-1", "operator_id" => "actor-1"},
                  4
                )}
             )

    calls = Agent.get(ctx.calls, & &1.calls)
    assert Enum.count(calls, &match?({:acquire, _, _}, &1)) == 1
    assert Enum.count(calls, &match?({:release, _, _, _}, &1)) == 1
  end

  test "Commander event ACK is applied only after durable emission", ctx do
    event = %{
      "type" => "job.event",
      "protocol_version" => 1,
      "remote_execution_id" => @execution_id,
      "event" => "workflow.started",
      "phase" => "inspect_auth",
      "metadata" => %{"central_job_id" => @job_id},
      "occurred_at" => "2026-09-06T00:00:00Z"
    }

    assert {:ok, _event} = Journal.append_event(ctx.journal, @execution_id, event)

    send(ctx.capability, {
      :event_ack,
      %EventAck{
        protocol_version: 1,
        remote_execution_id: @execution_id,
        highest_contiguous_sequence: 1
      }
    })

    Process.sleep(10)
    assert [%{"sequence" => 1}] = Journal.event_unacked(ctx.journal, @execution_id)

    assert :ok = Journal.mark_event_emitted(ctx.journal, @execution_id, 1)

    send(
      ctx.capability,
      {:event_ack,
       %EventAck{
         protocol_version: 1,
         remote_execution_id: @execution_id,
         highest_contiguous_sequence: 1
       }}
    )

    assert eventually(fn -> Journal.event_unacked(ctx.journal, @execution_id) == [] end)
  end

  test "workflow results over the application wire ceiling fail closed", ctx do
    request =
      rpc(
        "workflow.status",
        %{"central_job_id" => "oversized", "remote_execution_id" => @execution_id},
        5
      )

    assert {:error,
            %{
              class: "workflow",
              code: "workflow_result_too_large",
              retryable: false,
              details: %{}
            }} = GenServer.call(ctx.capability, {:rpc, request})
  end

  defp rpc(operation, payload, ordinal) do
    id = ordinal |> Integer.to_string() |> String.pad_leading(12, "0")

    %RPCRequest{
      protocol_version: 1,
      request_id: "00000000-0000-4000-8000-#{id}",
      capability: "browser.control",
      capability_version: 1,
      operation: operation,
      idempotency_key: "capability-workflow-#{ordinal}",
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: payload
    }
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
