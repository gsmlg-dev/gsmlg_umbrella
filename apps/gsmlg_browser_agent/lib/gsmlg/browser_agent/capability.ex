defmodule GSMLG.BrowserAgent.Capability do
  @moduledoc "Commander `browser.control/v1` capability for Manager and profile operations."

  use GenServer

  alias GSMLG.BrowserAgent.{
    ArtifactTransfer,
    Journal,
    ManagerMonitor,
    ProfileLeaseServer,
    RequestDedup,
    Session,
    WorkflowSupervisor
  }

  alias GSMLG.BrowserAgent.SessionSupervisor
  alias GSMLG.BrowserAgent.Backends.CloakBrowser
  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.{Capability, EventAck, RPCRequest}

  @max_wire_bytes 131_072

  @operations [
    "manager.status",
    "profiles.list",
    "profile.status",
    "profile.launch",
    "profile.stop",
    "session.open",
    "session.observe",
    "session.act",
    "session.manual_acquire",
    "session.manual_release",
    "session.close",
    "workflow.start",
    "workflow.status",
    "workflow.cancel",
    "workflow.resume",
    "workflow.reconcile",
    "artifact.fetch_inline",
    "artifact.upload",
    "artifact.ack"
  ]

  @manager_error_codes [
    "invalid_profile_id",
    "manager_invalid_request",
    "manager_invalid_response",
    "manager_license_denied",
    "manager_request_failed",
    "manager_response_too_large",
    "manager_timeout",
    "manager_unauthorized",
    "manager_unavailable",
    "operation_not_implemented",
    "profile_busy",
    "profile_not_found"
  ]

  @ambiguous_mutation_codes [
    "manager_invalid_response",
    "manager_response_too_large",
    "manager_timeout",
    "manager_unavailable"
  ]

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def descriptor(settings) do
    %Capability{
      id: "browser.control",
      version: 1,
      backend: settings.backend,
      operations: @operations,
      limits: %{
        "max_profiles_running" => 1,
        "max_sessions" => settings.max_concurrent_sessions,
        "max_workflows" => settings.max_concurrent_workflows
      },
      workflows: ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
    }
  end

  @impl true
  def init(opts) do
    settings = Keyword.fetch!(opts, :settings)
    registry = Keyword.get(opts, :registry, CapabilityRegistry)

    state = %{
      settings: settings,
      registry: registry,
      monitor: Keyword.get(opts, :monitor, ManagerMonitor),
      backend: Keyword.get(opts, :backend, CloakBrowser),
      backend_opts: Keyword.get(opts, :backend_opts, []),
      lease_server: Keyword.get(opts, :lease_server, ProfileLeaseServer),
      session_supervisor: Keyword.get(opts, :session_supervisor, SessionSupervisor),
      session_api: Keyword.get(opts, :session_api, Session),
      journal: Keyword.get(opts, :journal, Journal),
      workflow_api: Keyword.get(opts, :workflow_api, WorkflowSupervisor),
      workflow_supervisor: Keyword.get(opts, :workflow_supervisor, WorkflowSupervisor),
      artifact_api: Keyword.get(opts, :artifact_api, ArtifactTransfer),
      artifact_opts:
        Keyword.get(opts, :artifact_opts,
          max_upload_bytes: settings.max_artifact_bytes,
          max_raw_inline_bytes: settings.inline_artifact_max_bytes,
          allowed_upload_origins: settings.allowed_upload_origins
        )
    }

    with {:ok, generation} <- persistent_begin_generation(state.journal),
         :ok <- CapabilityRegistry.register(registry, descriptor(settings), self()) do
      {:ok, Map.put(state, :generation, generation)}
    else
      {:error, reason} -> {:stop, {:capability_registration_failed, reason}}
    end
  end

  @impl true
  def handle_call({:rpc, %RPCRequest{} = request}, _from, state) do
    result =
      case request_deadline(request) do
        :ok -> execute_deduplicated(request, state)
        {:error, code} -> capability_error(code, false)
      end

    {:reply, result, state}
  end

  def handle_call({:rpc, _invalid}, _from, state) do
    {:reply, capability_error("invalid_request", false), state}
  end

  @impl true
  def handle_info({:event_ack, %EventAck{} = ack}, state) do
    _ =
      Journal.ack_events(state.journal, ack.remote_execution_id, ack.highest_contiguous_sequence)

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp request_deadline(%RPCRequest{deadline_at: deadline_at}) when is_binary(deadline_at) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} ->
        if DateTime.compare(deadline, DateTime.utc_now()) == :gt,
          do: :ok,
          else: {:error, "deadline_exceeded"}

      {:error, _reason} ->
        {:error, "invalid_deadline"}
    end
  end

  defp request_deadline(_request), do: {:error, "invalid_deadline"}

  defp execute_deduplicated(request, state) do
    case persistent_claim(state.journal, request, state.generation) do
      :execute ->
        request
        |> dispatch_request(state)
        |> complete_new_request(request, state)

      {:recover, recovery} ->
        recover_request(request, recovery, state)

      {:replay, result} ->
        result

      {:in_progress, _request_id} ->
        capability_error("request_in_progress", true)

      {:error, :journal_unavailable} ->
        capability_error("journal_unavailable", true)

      {:error, reason} when is_atom(reason) ->
        capability_error(Atom.to_string(reason), false)

      {:error, _reason} ->
        capability_error("journal_unavailable", true)
    end
  end

  defp dispatch_request(%{operation: "workflow.start"} = request, state) do
    state.workflow_api.start(state.workflow_supervisor, request.payload, %{
      idempotency_key: request.idempotency_key,
      deadline_at: request.deadline_at
    })
    |> sanitize_workflow_start_result()
  end

  defp dispatch_request(request, state), do: dispatch(request.operation, request.payload, state)

  defp complete_new_request(result, request, state) do
    if recoverable_mutation_result?(request, result) do
      case persistent_defer(state.journal, request, request.request_id) do
        :ok -> result
        {:error, _reason} -> capability_error("journal_unavailable", true)
      end
    else
      case persistent_complete(state.journal, request, result) do
        :ok -> result
        {:error, _reason} -> capability_error("operation_outcome_unknown", true)
      end
    end
  end

  defp recoverable_mutation_result?(
         %{operation: operation},
         {:error, %{code: "operation_outcome_unknown"}}
       )
       when operation in ["profile.launch", "profile.stop"],
       do: true

  defp recoverable_mutation_result?(_request, _result), do: false

  defp recover_request(request, recovery, state) do
    context = recovery.request || request_context(request)

    decision =
      case request do
        %{operation: "workflow.start"} ->
          {:complete, dispatch_request(request, state)}

        %{operation: "artifact.upload"} ->
          {:retain, artifact_error(:artifact_upload_url_required, true)}

        _other ->
          recover_context(context, state)
      end

    finish_recovery(decision, request, recovery.request_id, state)
  end

  defp recover_context(context, state) do
    case context do
      %{operation: operation, payload: payload}
      when operation in ["profile.launch", "profile.stop"] ->
        recover_profile_mutation(operation, payload, state)

      %{operation: operation, payload: payload} ->
        {:complete, dispatch(operation, payload, state)}

      _invalid ->
        {:retain, capability_error("operation_outcome_unknown", true)}
    end
  end

  defp finish_recovery({:complete, result}, request, original_request_id, state) do
    case persistent_complete(state.journal, request, result, original_request_id) do
      :ok -> result
      {:error, _reason} -> capability_error("operation_outcome_unknown", true)
    end
  end

  defp finish_recovery({:retain, result}, request, original_request_id, state) do
    case persistent_defer(state.journal, request, original_request_id) do
      :ok -> result
      {:error, _reason} -> capability_error("journal_unavailable", true)
    end
  end

  defp recover_profile_mutation(
         "profile.launch",
         %{"profile_id" => profile_id} = payload,
         state
       )
       when map_size(payload) == 1 do
    case run_global_launch(state.lease_server, fn ->
           reconcile_profile_launch(profile_id, state)
         end) do
      {:error, :profile_busy} -> {:retain, capability_error("profile_busy", true)}
      {:error, %{} = error} -> {:retain, {:error, error}}
      decision -> decision
    end
  end

  defp recover_profile_mutation(operation, %{"profile_id" => profile_id} = payload, state)
       when map_size(payload) == 1 do
    case run_unleased(state.lease_server, profile_id, fn ->
           reconcile_profile_mutation(operation, profile_id, state)
         end) do
      {:error, :profile_busy} -> {:retain, capability_error("profile_busy", true)}
      {:error, %{} = error} -> {:retain, {:error, error}}
      decision -> decision
    end
  end

  defp recover_profile_mutation(operation, payload, state) do
    {:complete, dispatch(operation, payload, state)}
  end

  defp reconcile_profile_mutation(operation, profile_id, state) do
    desired = desired_profile_status(operation)

    case state.backend.profile_status(state.settings, profile_id, state.backend_opts) do
      {:ok, %{"status" => ^desired} = status} ->
        {:complete, recovered_profile_result(operation, profile_id, status)}

      {:ok, %{"status" => current}} when current in ["running", "stopped"] ->
        recover_with_mutation(operation, profile_id, state)

      {:error, _error} = error ->
        recovery_status_error(error)

      _invalid ->
        {:retain, capability_error("operation_outcome_unknown", true)}
    end
  end

  defp reconcile_profile_launch(profile_id, state) do
    case state.backend.profile_status(state.settings, profile_id, state.backend_opts) do
      {:ok, %{"status" => "running"} = status} ->
        {:complete, recovered_profile_result("profile.launch", profile_id, status)}

      {:ok, %{"status" => "stopped"}} ->
        state
        |> admit_profile_launch(profile_id)
        |> recovery_launch_decision()

      {:error, _error} = error ->
        recovery_status_error(error)

      _invalid ->
        {:retain, capability_error("operation_outcome_unknown", true)}
    end
  end

  defp recover_with_mutation("profile.stop", profile_id, state) do
    recovery_mutation_result(
      state.backend.stop_profile(state.settings, profile_id, state.backend_opts)
      |> mutation_result("profile.stop")
    )
  end

  defp recovery_mutation_result({:ok, result}) when is_map(result),
    do: {:complete, {:ok, result}}

  defp recovery_mutation_result(
         {:error, %{code: "operation_outcome_unknown"}} = manager_uncertain
       ),
       do: {:retain, manager_uncertain}

  defp recovery_mutation_result({:error, _error} = deterministic),
    do: {:complete, deterministic}

  defp recovery_mutation_result(_invalid),
    do: {:complete, manager_error("manager_invalid_response", false)}

  defp recovery_launch_decision({:error, %{code: "operation_outcome_unknown"}} = result),
    do: {:retain, result}

  defp recovery_launch_decision(result), do: {:complete, result}

  defp recovered_profile_result("profile.launch", profile_id, status) do
    result =
      status
      |> Map.take(["status", "runtime_mode", "viewer_mode"])
      |> Map.put("profile_id", profile_id)

    {:ok, result}
  end

  defp recovered_profile_result("profile.stop", profile_id, _status) do
    {:ok, %{"profile_id" => profile_id, "status" => "stopped"}}
  end

  defp desired_profile_status("profile.launch"), do: "running"
  defp desired_profile_status("profile.stop"), do: "stopped"

  defp request_context(request) do
    context =
      Map.take(request, [
        :capability,
        :capability_version,
        :operation,
        :idempotency_key,
        :payload
      ])

    if request.operation == "artifact.upload",
      do:
        put_in(
          context,
          [:payload],
          Map.drop(request.payload, ["upload_url", "required_headers"])
        ),
      else: context
  end

  defp persistent_begin_generation(journal) do
    RequestDedup.begin_generation(journal)
  catch
    :exit, _reason -> {:error, :journal_unavailable}
  end

  defp persistent_claim(journal, request, generation) do
    RequestDedup.claim(journal, request, generation)
  catch
    :exit, _reason -> {:error, :journal_unavailable}
  end

  defp persistent_complete(journal, request, result, request_id \\ nil) do
    case request_id do
      nil -> RequestDedup.complete(journal, request, result)
      request_id -> RequestDedup.complete(journal, request, result, request_id)
    end
  catch
    :exit, _reason -> {:error, :journal_unavailable}
  end

  defp persistent_defer(journal, request, request_id) do
    RequestDedup.defer(journal, request, request_id)
  catch
    :exit, _reason -> {:error, :journal_unavailable}
  end

  @impl true
  def terminate(_reason, state) do
    _ = CapabilityRegistry.unregister(state.registry, "browser.control")
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp dispatch("manager.status", payload, state) when map_size(payload) == 0 do
    {:ok, ManagerMonitor.snapshot(state.monitor)}
  end

  defp dispatch("profiles.list", payload, state) when map_size(payload) == 0 do
    state.backend.list_profiles(state.settings, state.backend_opts)
    |> sanitize_backend_result()
  end

  defp dispatch("profile.status", %{"profile_id" => profile_id} = payload, state)
       when map_size(payload) == 1 do
    state.backend.profile_status(state.settings, profile_id, state.backend_opts)
    |> sanitize_backend_result()
  end

  defp dispatch("profile.launch", %{"profile_id" => profile_id} = payload, state)
       when map_size(payload) == 1 do
    run_profile_launch(state.lease_server, fn ->
      admit_profile_launch(state, profile_id)
    end)
  end

  defp dispatch("profile.stop", %{"profile_id" => profile_id} = payload, state)
       when map_size(payload) == 1 do
    run_profile_mutation(state.lease_server, profile_id, fn ->
      state.backend.stop_profile(state.settings, profile_id, state.backend_opts)
      |> mutation_result("profile.stop")
    end)
  end

  defp dispatch("session.open", payload, state) when is_map(payload) do
    state.session_api.open(state.session_supervisor, payload)
    |> sanitize_session_result()
  end

  defp dispatch("session.observe", %{"session_id" => session_id} = payload, state)
       when map_size(payload) == 1 and is_binary(session_id) do
    state.session_api.observe(state.session_supervisor, session_id)
    |> sanitize_session_result()
  end

  defp dispatch(
         "session.act",
         %{"session_id" => session_id, "action" => action} = payload,
         state
       )
       when map_size(payload) == 2 and is_binary(session_id) and is_map(action) do
    state.session_api.act(state.session_supervisor, session_id, action)
    |> sanitize_session_result()
  end

  defp dispatch(
         "session.manual_acquire",
         %{"session_id" => session_id, "operator_id" => operator_id} = payload,
         state
       )
       when map_size(payload) == 2 and is_binary(session_id) and is_binary(operator_id) and
              operator_id != "" do
    state.session_api.manual_acquire(state.session_supervisor, session_id, operator_id)
    |> sanitize_session_result()
  end

  defp dispatch(
         "session.manual_release",
         %{
           "session_id" => session_id,
           "lease_id" => lease_id,
           "operator_id" => operator_id
         } = payload,
         state
       )
       when map_size(payload) == 3 and is_binary(session_id) and is_binary(lease_id) and
              lease_id != "" and is_binary(operator_id) and operator_id != "" do
    state.session_api.manual_release(
      state.session_supervisor,
      session_id,
      lease_id,
      operator_id
    )
    |> sanitize_session_result()
  end

  defp dispatch("session.close", %{"session_id" => session_id} = payload, state)
       when map_size(payload) == 1 and is_binary(session_id) do
    state.session_api.close(state.session_supervisor, session_id)
    |> sanitize_session_result()
  end

  defp dispatch(
         "workflow.status",
         %{"central_job_id" => central_id, "remote_execution_id" => remote_id} = payload,
         state
       )
       when map_size(payload) == 2 and is_binary(central_id) and is_binary(remote_id) do
    state.workflow_api.status(state.workflow_supervisor, central_id, remote_id)
    |> sanitize_workflow_result()
  end

  defp dispatch(
         "workflow.cancel",
         %{"central_job_id" => central_id, "remote_execution_id" => remote_id} = payload,
         state
       )
       when map_size(payload) == 2 and is_binary(central_id) and is_binary(remote_id) do
    state.workflow_api.cancel(state.workflow_supervisor, central_id, remote_id)
    |> sanitize_workflow_result()
  end

  defp dispatch(
         "workflow.resume",
         %{
           "central_job_id" => central_id,
           "remote_execution_id" => remote_id,
           "operator_id" => operator_id
         } = payload,
         state
       )
       when map_size(payload) == 3 and is_binary(central_id) and is_binary(remote_id) and
              is_binary(operator_id) do
    state.workflow_api.resume(state.workflow_supervisor, central_id, remote_id, operator_id)
    |> sanitize_workflow_result()
  end

  defp dispatch("workflow.reconcile", %{"central_job_id" => central_id} = payload, state)
       when map_size(payload) == 1 and is_binary(central_id) do
    state.workflow_api.reconcile(state.workflow_supervisor, central_id, nil)
    |> sanitize_workflow_result()
  end

  defp dispatch(
         "workflow.reconcile",
         %{"central_job_id" => central_id, "remote_execution_id" => remote_id} = payload,
         state
       )
       when map_size(payload) == 2 and is_binary(central_id) and is_binary(remote_id) do
    state.workflow_api.reconcile(state.workflow_supervisor, central_id, remote_id)
    |> sanitize_workflow_result()
  end

  defp dispatch(operation, payload, state)
       when operation in ["artifact.fetch_inline", "artifact.upload", "artifact.ack"] and
              is_map(payload) do
    state.artifact_api.dispatch(operation, payload, state.journal, state.artifact_opts)
    |> sanitize_artifact_result()
  end

  defp dispatch(operation, payload, _state) when operation in @operations and is_map(payload),
    do: capability_error("invalid_operation_payload", false)

  defp dispatch(_operation, _payload, _state),
    do: capability_error("operation_not_supported", false)

  defp run_profile_mutation(lease_server, profile_id, mutation) do
    case run_unleased(lease_server, profile_id, mutation) do
      {:error, :profile_busy} -> capability_error("profile_busy", true)
      result -> result
    end
  end

  defp run_profile_launch(lease_server, launch) do
    case run_global_launch(lease_server, launch) do
      {:error, :profile_busy} -> capability_error("profile_busy", true)
      result -> result
    end
  end

  defp admit_profile_launch(state, profile_id) do
    case state.backend.list_profiles(state.settings, state.backend_opts)
         |> sanitize_backend_result() do
      {:ok, profiles} when is_list(profiles) ->
        decide_profile_launch(profiles, profile_id, state)

      {:error, _error} = error ->
        error

      _invalid ->
        manager_error("manager_invalid_response", false)
    end
  end

  defp decide_profile_launch(profiles, profile_id, state) do
    if valid_profile_states?(profiles) do
      cond do
        Enum.any?(profiles, fn profile ->
          profile["id"] != profile_id and profile["status"] == "running"
        end) ->
          capability_error("profile_busy", true)

        Enum.any?(profiles, fn profile ->
          profile["id"] == profile_id and profile["status"] == "running"
        end) ->
          recovered_profile_result("profile.launch", profile_id, %{"status" => "running"})

        true ->
          state.backend.launch_profile(state.settings, profile_id, state.backend_opts)
          |> mutation_result("profile.launch")
      end
    else
      manager_error("manager_invalid_response", false)
    end
  end

  defp recovery_status_error(error) do
    case sanitize_backend_result(error) do
      {:error, %{code: "profile_not_found"}} = deterministic ->
        {:complete, deterministic}

      {:error, _unable_to_verify} ->
        {:retain, capability_error("operation_outcome_unknown", true)}
    end
  end

  defp mutation_result({:ok, result}, _operation) when is_map(result), do: {:ok, result}

  defp mutation_result({:ok, _invalid}, _operation),
    do: capability_error("operation_outcome_unknown", true)

  defp mutation_result(result, operation) do
    case sanitize_backend_result(result) do
      {:error, %{code: code}} when code in @ambiguous_mutation_codes ->
        capability_error("operation_outcome_unknown", true)

      {:error, %{code: "profile_busy"}} when operation == "profile.launch" ->
        capability_error("operation_outcome_unknown", true)

      sanitized ->
        sanitized
    end
  end

  defp sanitize_backend_result({:ok, result}), do: {:ok, result}

  defp sanitize_backend_result({:error, %{class: "manager", code: code, retryable: retryable}})
       when code in @manager_error_codes and is_boolean(retryable) do
    manager_error(code, retryable)
  end

  defp sanitize_backend_result(_invalid), do: manager_error("manager_invalid_response", false)

  defp sanitize_session_result({:ok, result}) when is_map(result), do: {:ok, result}

  defp sanitize_session_result({:error, reason}) when is_atom(reason) do
    session_error(reason, session_retryable?(reason))
  end

  defp sanitize_session_result(_invalid), do: session_error(:session_failed, false)

  defp sanitize_workflow_result({:ok, result}) when is_map(result) do
    if encoded_size(result) <= @max_wire_bytes,
      do: {:ok, result},
      else: workflow_error(:workflow_result_too_large, false)
  end

  defp sanitize_workflow_result({:error, reason}) when is_atom(reason),
    do: workflow_error(reason, workflow_retryable?(reason))

  defp sanitize_workflow_result(_invalid), do: workflow_error(:workflow_failed, false)

  defp sanitize_workflow_start_result({:ok, %{"remote_execution_id" => remote_execution_id}})
       when is_binary(remote_execution_id),
       do: {:accepted, remote_execution_id}

  defp sanitize_workflow_start_result({:error, reason}) when is_atom(reason),
    do: workflow_error(reason, workflow_retryable?(reason))

  defp sanitize_workflow_start_result(_invalid), do: workflow_error(:workflow_failed, false)

  defp sanitize_artifact_result({:ok, result}) when is_map(result), do: {:ok, result}

  defp sanitize_artifact_result({:error, reason}) when is_atom(reason),
    do: artifact_error(reason, reason in [:artifact_upload_failed, :artifact_transport_failed])

  defp sanitize_artifact_result(_invalid), do: artifact_error(:artifact_transfer_failed, false)

  defp encoded_size(value) do
    value
    |> JSON.encode!()
    |> byte_size()
  rescue
    _exception -> @max_wire_bytes + 1
  end

  defp session_retryable?(reason),
    do: reason in [:session_unavailable, :session_capacity_exceeded, :session_close_unconfirmed]

  defp workflow_retryable?(reason),
    do:
      reason in [
        :workflow_unavailable,
        :workflow_cancel_unconfirmed,
        :workflow_checkpoint_failed,
        :workflow_recovery_failed
      ]

  defp valid_profile_states?(profiles) do
    Enum.all?(profiles, fn
      %{"id" => id, "status" => status}
      when is_binary(id) and id != "" and status in ["running", "stopped"] ->
        true

      _invalid ->
        false
    end)
  end

  defp run_unleased(lease_server, profile_id, mutation) do
    ProfileLeaseServer.run_unleased(lease_server, profile_id, mutation)
  catch
    :exit, _reason -> capability_error("operation_outcome_unknown", true)
  end

  defp run_global_launch(lease_server, launch) do
    ProfileLeaseServer.run_global_launch(lease_server, launch)
  catch
    :exit, _reason -> capability_error("operation_outcome_unknown", true)
  end

  defp capability_error(code, retryable) do
    {:error,
     %{
       class: "capability",
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action: "none",
       details: %{}
     }}
  end

  defp manager_error(code, retryable) do
    {:error,
     %{
       class: "manager",
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action: "none",
       details: %{}
     }}
  end

  defp session_error(reason, retryable) do
    code = Atom.to_string(reason)

    {:error,
     %{
       class: session_error_class(reason),
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action: if(reason == :action_outcome_unknown, do: "reconcile", else: "none"),
       details: %{}
     }}
  end

  defp session_error_class(reason) when reason in [:lease_conflict, :profile_busy], do: "lease"

  defp session_error_class(reason)
       when reason in [:stale_observation, :observation_failed, :observation_too_large],
       do: "observation"

  defp session_error_class(:navigation_not_allowed), do: "policy"

  defp session_error_class(reason)
       when reason in [:action_outcome_unknown, :action_target_not_found],
       do: "action"

  defp session_error_class(_reason), do: "session"

  defp workflow_error(reason, retryable) do
    code = Atom.to_string(reason)

    {:error,
     %{
       class: "workflow",
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action:
         if(reason in [:operator_identity_required, :operator_identity_mismatch],
           do: "authenticate",
           else: "none"
         ),
       details: %{}
     }}
  end

  defp artifact_error(reason, retryable) do
    code = Atom.to_string(reason)

    {:error,
     %{
       class: "artifact",
       code: code,
       message: code |> String.replace("_", " ") |> String.capitalize(),
       retryable: retryable,
       human_action: "none",
       details: %{}
     }}
  end
end
