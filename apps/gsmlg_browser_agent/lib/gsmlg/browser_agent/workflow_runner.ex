defmodule GSMLG.BrowserAgent.WorkflowRunner do
  @moduledoc false

  use GenServer, restart: :transient

  alias GSMLG.BrowserAgent.{ArtifactOutbox, Intervention, Journal, Policy, Telemetry, Workflow}
  alias GSMLG.BrowserAgent.Sites.Gemini.UIContract
  alias GSMLG.BrowserAgent.Workflow.Decision

  @terminal [:completed, :failed, :cancelled]

  def start_link(opts) do
    checkpoint = Keyword.fetch!(opts, :checkpoint)

    name =
      {:via, Registry, {Keyword.fetch!(opts, :registry_name), checkpoint.remote_execution_id}}

    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    checkpoint = Keyword.fetch!(opts, :checkpoint)

    %{
      id: {__MODULE__, checkpoint.remote_execution_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  def snapshot(checkpoint, journal) do
    events = Journal.event_unacked(journal, checkpoint.remote_execution_id)

    artifacts =
      journal
      |> ArtifactOutbox.pending()
      |> Enum.filter(&(&1["job_id"] == checkpoint.central_job_id))

    %{
      "remote_execution_id" => checkpoint.remote_execution_id,
      "central_job_id" => checkpoint.central_job_id,
      "remote_session_id" => checkpoint.session_id,
      "workflow" => checkpoint.workflow,
      "workflow_version" => checkpoint.workflow_version,
      "status" => Atom.to_string(checkpoint.status),
      "phase" => Atom.to_string(checkpoint.phase),
      "deadline_at" => checkpoint.deadline_at,
      "chat_url" => chat_url(checkpoint),
      "intervention" => intervention_snapshot(checkpoint.intervention),
      "last_sequence" => Journal.event_last_sequence(journal, checkpoint.remote_execution_id),
      "result" => result_snapshot(Map.get(checkpoint, :result), artifacts),
      "artifacts" => artifacts,
      "outbox" => %{
        "unacked_event_count" => length(events),
        "pending_artifact_count" => length(artifacts)
      }
    }
  end

  defp result_snapshot(nil, _artifacts), do: nil

  defp result_snapshot(result, artifacts) when is_map(result) do
    %{
      "available" => true,
      "artifact_ids" => Enum.map(artifacts, & &1["artifact_id"]),
      "content_hashes" => Map.new(artifacts, &{&1["kind"], &1["sha256"]})
    }
  end

  @impl true
  def init(opts) do
    supplied = Keyword.fetch!(opts, :checkpoint)
    journal = Keyword.fetch!(opts, :journal)

    checkpoint =
      case Journal.workflow_get(journal, supplied.remote_execution_id) do
        {:ok, %{runner_generation: generation} = persisted}
        when generation == supplied.runner_generation ->
          persisted

        _missing_or_stale ->
          nil
      end

    if is_nil(checkpoint) do
      {:stop, :stale_workflow_generation}
    else
      init_state(opts, checkpoint, journal)
    end
  end

  defp init_state(opts, checkpoint, journal) do
    state = %{
      checkpoint: checkpoint,
      journal: journal,
      session_api: Keyword.fetch!(opts, :session_api),
      session_supervisor: Keyword.fetch!(opts, :session_supervisor),
      state_dir: Keyword.fetch!(opts, :state_dir),
      max_observation_bytes: Keyword.get(opts, :max_observation_bytes, 1_048_576),
      max_artifact_bytes: Keyword.get(opts, :max_artifact_bytes, 104_857_600),
      auto_run: Keyword.get(opts, :auto_run, true),
      clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
      timer: nil
    }

    {:ok, state, {:continue, :prepare}}
  end

  @impl true
  def handle_continue(:prepare, state) do
    case prepare_with_deadline(state) do
      {:ok, state} -> {:noreply, maybe_schedule(state)}
      {:error, state} -> {:noreply, state}
    end
  end

  defp prepare_with_deadline(%{checkpoint: %{status: status}} = state)
       when status in @terminal or status == :cancelling,
       do: prepare(state)

  defp prepare_with_deadline(state) do
    if expired?(state.checkpoint.deadline_at, state.clock.()) do
      case fail(state, :workflow_deadline_exceeded) do
        {:error, _reason, state} -> {:error, state}
        {:ok, state} -> {:error, state}
      end
    else
      prepare(state)
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state),
    do: {:reply, {:ok, snapshot(state.checkpoint, state.journal)}, state}

  def handle_call(:cancel, _from, state), do: reply_transition(cancel(state))

  def handle_call({:intervene, reason}, _from, state),
    do: reply_transition(intervene(state, reason))

  def handle_call({:resume, operator_id}, _from, state),
    do: reply_transition(resume(state, operator_id))

  def handle_call(:reconcile, _from, state) do
    state = reconcile(state)
    {:reply, {:ok, snapshot(state.checkpoint, state.journal)}, state}
  end

  def handle_call(:step, _from, state), do: reply_transition(execute_step(state))

  @impl true
  def handle_info(:step, state) do
    case execute_step(%{state | timer: nil}) do
      {:ok, state} -> {:noreply, maybe_schedule(state)}
      {:error, _reason, state} -> {:noreply, state}
    end
  end

  defp reply_transition({:ok, state}),
    do: {:reply, {:ok, snapshot(state.checkpoint, state.journal)}, maybe_schedule(state)}

  defp reply_transition({:error, reason, state}), do: {:reply, {:error, reason}, state}

  defp prepare(%{checkpoint: %{status: status}} = state) when status in @terminal,
    do: {:ok, state}

  defp prepare(%{checkpoint: %{status: :cancelling}} = state),
    do: normalize_prepare(finish_cancel(state))

  defp prepare(%{checkpoint: %{status: :intervening}} = state), do: recover_intervention(state)

  defp prepare(%{checkpoint: %{pending_decision: %Decision{type: :action}}} = state) do
    _ = state.session_api.reconcile(state.session_supervisor, state.checkpoint.session_id)
    checkpoint = %{state.checkpoint | status: :running}
    normalize_prepare(intervene(%{state | checkpoint: checkpoint}, :action_outcome_unknown))
  end

  defp prepare(%{checkpoint: %{session_id: session_id}} = state) when is_binary(session_id),
    do: {:ok, state}

  defp prepare(state) do
    checkpoint = state.checkpoint
    {:ok, workflow_module} = Workflow.module(checkpoint.workflow)

    params = %{
      "central_session_id" => checkpoint.remote_execution_id,
      "remote_execution_id" => checkpoint.remote_execution_id,
      "artifact_job_id" => checkpoint.central_job_id,
      "profile_id" => checkpoint.profile_id,
      "mode" => "workflow",
      "authorized_origins" => workflow_module.required_origins(),
      "required_profile_capabilities" => workflow_module.profile_capabilities(),
      "ttl_ms" => remaining_ms(checkpoint.deadline_at, state.clock.()),
      "permissions" => %{"screenshot" => true, "download" => false}
    }

    case state.session_api.open_workflow(state.session_supervisor, params) do
      {:ok, session} when is_map(session) -> prepare_opened(state, session)
      _error -> fail_prepare(state, :session_open_failed)
    end
  end

  defp prepare_opened(state, session) do
    session_id = session["remote_session_id"] || session["session_id"]

    if is_binary(session_id) do
      checkpoint = state.checkpoint
      workflow_state = %{checkpoint.workflow_state | phase: :inspect_auth}

      updated = %{
        checkpoint
        | status: :running,
          phase: :inspect_auth,
          workflow_state: workflow_state,
          session_id: session_id
      }

      {updated, phase_duration_ms} = advance_phase(updated, checkpoint, state.clock.())

      with :ok <- persist(state, updated),
           :ok <- emit(state, updated, "accepted", "workflow.accepted"),
           :ok <- emit(state, updated, "started", "workflow.started") do
        :ok =
          Telemetry.workflow_transition(updated, phase_duration_ms, phase: checkpoint.phase)

        {:ok, %{state | checkpoint: updated}}
      else
        _error ->
          _ = state.session_api.close(state.session_supervisor, session_id)
          fail_prepare(state, :workflow_checkpoint_failed)
      end
    else
      fail_prepare(state, :session_open_failed)
    end
  end

  defp cancel(%{checkpoint: %{status: status}} = state) when status in @terminal,
    do: {:ok, state}

  defp cancel(state) do
    intent = %{state.checkpoint | status: :cancelling}

    case persist(state, intent) do
      :ok -> finish_cancel(%{state | checkpoint: intent})
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp finish_cancel(state) do
    result =
      if is_binary(state.checkpoint.session_id),
        do: state.session_api.close(state.session_supervisor, state.checkpoint.session_id),
        else: {:ok, %{}}

    case result do
      {:ok, _snapshot} ->
        updated = %{state.checkpoint | status: :cancelled}

        with :ok <- persist(state, updated),
             :ok <- emit(state, updated, "cancelled", "workflow.cancelled") do
          {:ok, cancel_timer(%{state | checkpoint: updated})}
        else
          _error -> {:error, :workflow_checkpoint_failed, state}
        end

      _error ->
        updated = %{state.checkpoint | status: :orphaned}

        case persist(state, updated) do
          :ok -> {:error, :workflow_cancel_unconfirmed, %{state | checkpoint: updated}}
          _error -> {:error, :workflow_checkpoint_failed, state}
        end
    end
  end

  defp intervene(state, reason) do
    cond do
      reason not in Intervention.reason_codes() ->
        {:error, :invalid_intervention_reason, state}

      expired?(state.checkpoint.deadline_at, state.clock.()) ->
        fail(state, :workflow_deadline_exceeded)

      state.checkpoint.status == :waiting_human ->
        {:ok, state}

      state.checkpoint.status != :running ->
        {:error, :workflow_not_running, state}

      true ->
        begin_handoff(state, reason)
    end
  end

  defp begin_handoff(state, reason) do
    checkpoint = state.checkpoint

    with {:ok, intervention} <-
           Intervention.new(reason, checkpoint.requested_by_actor_id),
         intervention = Map.put(intervention, :resume_phase, checkpoint.phase),
         intent = %{
           checkpoint
           | status: :intervening,
             intervention: intervention,
             fresh_observation_required: true
         },
         :ok <- persist(state, intent) do
      finish_handoff(%{state | checkpoint: intent})
    else
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp finish_handoff(state) do
    checkpoint = state.checkpoint

    case state.session_api.manual_handoff(
           state.session_supervisor,
           checkpoint.session_id,
           checkpoint.intervention.operator_id
         ) do
      {:ok, _snapshot} ->
        workflow_state = %{
          checkpoint.workflow_state
          | status: :waiting_human,
            resume_phase: checkpoint.intervention.resume_phase
        }

        updated = %{checkpoint | status: :waiting_human, workflow_state: workflow_state}

        with :ok <- persist(state, updated),
             :ok <-
               emit(
                 state,
                 updated,
                 "intervention:#{checkpoint.intervention.reason}",
                 "intervention.required",
                 %{"reason" => Atom.to_string(checkpoint.intervention.reason)}
               ) do
          :ok = Telemetry.intervention_required(updated, checkpoint.intervention.reason)
          {:ok, cancel_timer(%{state | checkpoint: updated})}
        else
          _error -> {:error, :workflow_checkpoint_failed, state}
        end

      {:error, reason} ->
        {:error, reason, state}

      _invalid ->
        {:error, :manual_handoff_failed, state}
    end
  end

  defp recover_intervention(state) do
    case state.session_api.reconcile(state.session_supervisor, state.checkpoint.session_id) do
      {:ok, %{"status" => "waiting_human"}} ->
        updated = %{state.checkpoint | status: :waiting_human}

        case persist(state, updated) do
          :ok -> {:ok, %{state | checkpoint: updated}}
          _error -> {:error, state}
        end

      {:ok, _snapshot} ->
        normalize_prepare(finish_handoff(state))

      _error ->
        updated = %{state.checkpoint | status: :orphaned}
        _ = persist(state, updated)
        {:error, %{state | checkpoint: updated}}
    end
  end

  defp resume(state, operator_id) when not is_binary(operator_id) or operator_id == "",
    do: {:error, :operator_identity_required, state}

  defp resume(%{checkpoint: %{status: status}} = state, _operator_id)
       when status != :waiting_human,
       do: {:error, :workflow_not_waiting_human, state}

  defp resume(state, operator_id) do
    checkpoint = state.checkpoint

    with false <- expired?(checkpoint.deadline_at, state.clock.()),
         true <- operator_id == checkpoint.intervention.operator_id,
         {:ok, _snapshot} <-
           state.session_api.resume_automation(state.session_supervisor, checkpoint.session_id),
         {:ok, observation} <-
           state.session_api.observe(state.session_supervisor, checkpoint.session_id) do
      workflow_state = %{
        checkpoint.workflow_state
        | status: :running,
          phase: checkpoint.intervention.resume_phase,
          resume_phase: nil
      }

      updated = %{
        checkpoint
        | status: :running,
          phase: workflow_state.phase,
          workflow_state: workflow_state,
          intervention: nil,
          fresh_observation_required: false,
          last_observation: observation,
          resumed_by_operator_id: operator_id
      }

      with :ok <- persist(state, updated),
           :ok <- emit(state, updated, "intervention-cleared", "intervention.cleared") do
        {:ok, %{state | checkpoint: updated}}
      else
        _error -> {:error, :workflow_checkpoint_failed, state}
      end
    else
      true -> fail(state, :workflow_deadline_exceeded)
      false -> {:error, :operator_identity_mismatch, state}
      {:error, reason} -> block_after_resume_failure(state, reason)
      _invalid -> block_after_resume_failure(state, :observation_failed)
    end
  end

  defp block_after_resume_failure(state, reason) do
    updated =
      state.checkpoint
      |> Map.put(:status, :orphaned)
      |> Map.put(:intervention, nil)
      |> Map.put(:fresh_observation_required, true)
      |> Map.put(:failure_code, reason)

    case persist(state, updated) do
      :ok -> {:error, reason, %{state | checkpoint: updated}}
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp reconcile(%{checkpoint: %{status: status}} = state) when status in @terminal, do: state

  defp reconcile(state) do
    if expired?(state.checkpoint.deadline_at, state.clock.()) do
      case fail(state, :workflow_deadline_exceeded) do
        {:error, _reason, state} -> state
        {:ok, state} -> state
      end
    else
      do_reconcile(state)
    end
  end

  defp do_reconcile(state) do
    case state.session_api.reconcile(state.session_supervisor, state.checkpoint.session_id) do
      {:ok, %{"status" => "closed"}} when state.checkpoint.status == :cancelling ->
        case finish_cancel(state) do
          {:ok, state} -> state
          {:error, _reason, state} -> state
        end

      {:ok, %{"status" => "waiting_human"}} when not is_nil(state.checkpoint.intervention) ->
        update_status(state, :waiting_human)

      {:ok, %{"status" => status}} when status in ["ready", "acting", "waiting"] ->
        update_status(state, :running)

      {:ok, _snapshot} ->
        state

      _error ->
        update_status(state, :orphaned)
    end
  end

  defp update_status(state, status) do
    updated = %{state.checkpoint | status: status}
    if persist(state, updated) == :ok, do: %{state | checkpoint: updated}, else: state
  end

  defp execute_step(%{checkpoint: %{status: status}} = state) when status != :running,
    do: {:ok, state}

  defp execute_step(state) do
    if expired?(state.checkpoint.deadline_at, state.clock.()),
      do: fail(state, :workflow_deadline_exceeded),
      else: observe_and_decide(state)
  end

  defp observe_and_decide(state) do
    checkpoint = state.checkpoint

    with {:ok, observation} <-
           state.session_api.observe(state.session_supervisor, checkpoint.session_id),
         :ok <-
           Policy.validate_observation(observation, %{
             max_observation_bytes: state.max_observation_bytes
           }),
         {:ok, snapshot} <- recognize_observation(observation),
         {:ok, module} <- Workflow.module(checkpoint.workflow),
         {:ok, next_workflow_state, %Decision{} = decision} <-
           module.transition(checkpoint.workflow_state, snapshot),
         {:ok, state} <- checkpoint_decision(state, next_workflow_state, decision, observation) do
      execute_decision(state, decision, observation)
    else
      {:error, :ui_contract_invalid_observation} -> intervene(state, :ui_contract_mismatch)
      {:error, reason} when is_atom(reason) -> fail(state, reason)
      _invalid -> fail(state, :workflow_decision_invalid)
    end
  end

  defp recognize_observation(%{kind: kind} = observation) when is_atom(kind),
    do: {:ok, observation}

  defp recognize_observation(observation), do: UIContract.recognize(observation)

  defp checkpoint_decision(state, workflow_state, decision, observation) do
    updated = %{
      state.checkpoint
      | phase: workflow_state.phase,
        workflow_state: workflow_state,
        pending_decision: decision,
        last_observation: observation
    }

    {updated, phase_duration_ms} = advance_phase(updated, state.checkpoint, state.clock.())

    case persist(state, updated) do
      :ok ->
        emit_phase_transition(updated, state.checkpoint, phase_duration_ms)
        {:ok, %{state | checkpoint: updated}}

      _error ->
        {:error, :workflow_checkpoint_failed}
    end
  end

  defp execute_decision(state, %Decision{type: :action, action: model_action}, observation) do
    checkpoint = state.checkpoint
    revision = observation[:revision] || observation["revision"]
    model_action = Map.put(model_action, "expected_revision", revision)
    {:ok, module} = Workflow.module(checkpoint.workflow)

    context = %{
      revision: revision,
      allowed_origins: module.required_origins(),
      allow_css_locator: false
    }

    with {:ok, _validated} <- Policy.validate_decision(model_action, context) do
      action_number = checkpoint.action_number + 1

      action =
        model_action
        |> Map.put("action_id", "workflow-action-#{action_number}")
        |> Map.put("session_id", checkpoint.session_id)
        |> Map.put(
          "timeout_ms",
          min(remaining_ms(checkpoint.deadline_at, state.clock.()), 120_000)
        )
        |> Map.put_new("preconditions", [])

      pending = %Decision{state.checkpoint.pending_decision | action: action}
      updated = %{checkpoint | pending_decision: pending}

      case persist(state, updated) do
        :ok -> execute_action(%{state | checkpoint: updated}, action, action_number)
        _error -> {:error, :workflow_checkpoint_failed, state}
      end
    else
      {:error, reason} -> fail(state, reason)
    end
  end

  defp execute_decision(state, %Decision{type: :wait, wait_ms: wait_ms}, _observation) do
    delay = min(wait_ms, remaining_ms(state.checkpoint.deadline_at, state.clock.()))

    case finish_decision(state, %{}) do
      {:ok, state} -> {:ok, schedule_after(state, delay)}
      other -> other
    end
  end

  defp execute_decision(
         state,
         %Decision{type: :emit_event, event: event, metadata: metadata},
         _observation
       ) do
    with :ok <- emit(state, state.checkpoint, "phase:#{state.checkpoint.phase}", event, metadata),
         {:ok, state} <- finish_decision(state, %{}) do
      {:ok, state}
    else
      {:error, reason, state} -> {:error, reason, state}
      _error -> {:error, :event_outbox_failed, state}
    end
  end

  defp execute_decision(state, %Decision{type: :request_human, reason: reason}, _observation) do
    checkpoint = %{state.checkpoint | status: :running}
    intervene(%{state | checkpoint: checkpoint}, reason)
  end

  defp execute_decision(state, %Decision{type: :fail, code: code}, _observation),
    do: fail(state, code)

  defp execute_decision(state, %Decision{type: :complete, result: result}, observation) do
    with {:ok, state} <- maybe_capture_screenshot(state, result, observation) do
      updated = %{
        state.checkpoint
        | status: :collecting_artifacts,
          result: result,
          pending_decision: nil
      }

      case persist(state, updated) do
        :ok -> produce_artifacts(%{state | checkpoint: updated})
        _error -> {:error, :workflow_checkpoint_failed, state}
      end
    end
  end

  defp execute_decision(state, _invalid, _observation),
    do: fail(state, :workflow_decision_invalid)

  defp execute_action(state, action, action_number) do
    case state.session_api.act(state.session_supervisor, state.checkpoint.session_id, action) do
      {:ok, result} ->
        finish_decision(state, %{action_result: result, action_number: action_number})

      {:error, :action_outcome_unknown} ->
        intervene_after_unknown(state)

      {:error, reason} ->
        fail(state, reason)

      _invalid ->
        intervene_after_unknown(state)
    end
  end

  defp maybe_capture_screenshot(state, result, observation) do
    if "screenshot.png" in state.checkpoint.output_formats do
      revision = observation[:revision] || observation["revision"]
      action_number = state.checkpoint.action_number + 1

      action = %{
        "action_id" => "workflow-action-#{action_number}",
        "session_id" => state.checkpoint.session_id,
        "expected_revision" => revision,
        "type" => "screenshot",
        "timeout_ms" => min(remaining_ms(state.checkpoint.deadline_at, state.clock.()), 120_000),
        "preconditions" => [],
        "postconditions" => []
      }

      pending = Decision.action(action)
      updated = %{state.checkpoint | result: result, pending_decision: pending}
      state = %{state | checkpoint: updated}

      with :ok <- persist(state, updated),
           {:ok, response} <-
             state.session_api.act(state.session_supervisor, updated.session_id, action),
           :ok <- validate_screenshot_response(response, updated),
           {:ok, state} <-
             finish_decision(state, %{result: result, action_number: action_number}) do
        {:ok, state}
      else
        {:error, reason, state} -> {:error, reason, state}
        {:error, reason} -> fail(state, reason)
        _invalid -> fail(state, :workflow_artifact_failed)
      end
    else
      {:ok, state}
    end
  end

  defp validate_screenshot_response(response, checkpoint) do
    expected_id =
      GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(
        checkpoint.remote_execution_id,
        "screenshot.png"
      )

    with %{"output" => %{"artifact" => manifest}} <- response,
         true <- manifest["artifact_id"] == expected_id,
         true <- manifest["job_id"] == checkpoint.central_job_id,
         true <- manifest["kind"] == "screenshot.png",
         true <-
           get_in(manifest, ["metadata", "remote_execution_id"]) ==
             checkpoint.remote_execution_id do
      :ok
    else
      _invalid -> {:error, :workflow_artifact_failed}
    end
  end

  defp intervene_after_unknown(state) do
    checkpoint = %{state.checkpoint | status: :running}
    intervene(%{state | checkpoint: checkpoint}, :action_outcome_unknown)
  end

  defp finish_decision(state, additions) do
    updated = state.checkpoint |> Map.put(:pending_decision, nil) |> Map.merge(additions)

    case persist(state, updated) do
      :ok -> {:ok, %{state | checkpoint: updated}}
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp produce_artifacts(state) do
    case GSMLG.BrowserAgent.WorkflowArtifacts.produce(
           state.journal,
           state.state_dir,
           state.checkpoint,
           max_bytes: state.max_artifact_bytes
         ) do
      {:ok, manifests} -> emit_artifacts(state, manifests)
      {:error, reason} -> fail(state, reason)
    end
  end

  defp emit_artifacts(state, manifests) do
    result =
      Enum.reduce_while(manifests, :ok, fn manifest, :ok ->
        key = "artifact:#{manifest["artifact_id"]}"

        case emit(state, state.checkpoint, key, "artifact.available", %{
               "artifact_id" => manifest["artifact_id"],
               "content_hash" => manifest["sha256"]
             }) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    case result do
      :ok -> complete(%{state | checkpoint: Map.put(state.checkpoint, :artifacts, manifests)})
      _error -> {:error, :event_outbox_failed, state}
    end
  end

  defp complete(state) do
    updated = %{state.checkpoint | status: :completed}

    with :ok <- persist(state, updated),
         :ok <- emit(state, updated, "result", "result.available"),
         :ok <- emit(state, updated, "completed", "workflow.completed") do
      {:ok, cancel_timer(%{state | checkpoint: updated})}
    else
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp fail_prepare(state, code) do
    case fail(state, code) do
      {:error, _code, state} -> {:error, state}
      {:ok, state} -> {:error, state}
    end
  end

  defp fail(state, code) do
    updated = state.checkpoint |> Map.put(:status, :failed) |> Map.put(:failure_code, code)

    with :ok <- persist(state, updated),
         :ok <-
           emit(state, updated, "failed", "workflow.failed", %{"code" => Atom.to_string(code)}) do
      :ok =
        Telemetry.workflow_transition(
          updated,
          phase_duration_ms(state.checkpoint, state.clock.()),
          phase: state.checkpoint.phase,
          failure_code: code
        )

      {:error, code, cancel_timer(%{state | checkpoint: updated})}
    else
      _error -> {:error, :workflow_checkpoint_failed, state}
    end
  end

  defp normalize_prepare({:ok, state}), do: {:ok, state}
  defp normalize_prepare({:error, _reason, state}), do: {:error, state}

  defp persist(state, checkpoint),
    do: Journal.workflow_update(state.journal, checkpoint, checkpoint.runner_generation)

  defp advance_phase(updated, previous, now) do
    if updated.phase == previous.phase do
      {updated, nil}
    else
      {%{updated | phase_started_at: now}, phase_duration_ms(previous, now)}
    end
  end

  defp emit_phase_transition(_updated, _previous, nil), do: :ok

  defp emit_phase_transition(updated, previous, duration_ms) do
    Telemetry.workflow_transition(updated, duration_ms, phase: previous.phase)
  end

  defp phase_duration_ms(checkpoint, now) do
    case Map.get(checkpoint, :phase_started_at) do
      %DateTime{} = started_at -> max(DateTime.diff(now, started_at, :millisecond), 0)
      _missing -> 0
    end
  end

  defp emit(state, checkpoint, key, event, metadata \\ %{}) do
    event_map = %{
      "type" => "job.event",
      "protocol_version" => 1,
      "remote_execution_id" => checkpoint.remote_execution_id,
      "event" => event,
      "phase" => Atom.to_string(checkpoint.phase),
      "metadata" => Map.put(metadata, "central_job_id", checkpoint.central_job_id),
      "occurred_at" => DateTime.to_iso8601(state.clock.())
    }

    case Journal.append_event_once(state.journal, checkpoint.remote_execution_id, key, event_map) do
      {:ok, _event} -> :ok
      {:replay, _event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_schedule(%{auto_run: true, checkpoint: %{status: :running}, timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :step, 1_000)}

  defp maybe_schedule(state), do: state

  defp schedule_after(%{auto_run: true, timer: nil} = state, delay),
    do: %{state | timer: Process.send_after(self(), :step, max(delay, 1))}

  defp schedule_after(state, _delay), do: state

  defp cancel_timer(%{timer: timer} = state) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  defp cancel_timer(state), do: state

  defp remaining_ms(deadline_at, now) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} -> max(DateTime.diff(deadline, now, :millisecond), 1)
      {:error, _reason} -> 1
    end
  end

  defp expired?(deadline_at, now) do
    case DateTime.from_iso8601(deadline_at) do
      {:ok, deadline, _offset} -> DateTime.compare(deadline, now) != :gt
      {:error, _reason} -> true
    end
  end

  defp intervention_snapshot(nil), do: nil

  defp intervention_snapshot(intervention) do
    %{
      "reason" => Atom.to_string(intervention.reason),
      "reason_code" => intervention.reason_code,
      "operator_id" => intervention.operator_id,
      "instructions" => intervention.instructions,
      "resume_phase" => Atom.to_string(intervention.resume_phase)
    }
  end

  defp chat_url(checkpoint) do
    observation = Map.get(checkpoint, :last_observation) || %{}
    url = observation[:url] || observation["url"]

    case URI.parse(url || "") do
      %URI{scheme: "https", host: "gemini.google.com", userinfo: nil, port: port} = uri
      when is_binary(url) and byte_size(url) in 1..2_048 ->
        if port in [nil, 443], do: URI.to_string(%{uri | fragment: nil}), else: nil

      _not_authorized ->
        nil
    end
  end
end
