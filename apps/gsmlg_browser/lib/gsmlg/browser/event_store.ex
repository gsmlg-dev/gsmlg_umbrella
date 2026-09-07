defmodule GSMLG.Browser.EventStore do
  @moduledoc false

  import Ecto.Query

  alias GSMLG.Browser.{Enabled, Job, JobEvent, JobState, Node, Notifier, Profile, Sanitizer}
  alias GSMLG.Browser.Workers.ReconcileWorker
  alias GSMLG.CommandPlatform.RPCDispatcher
  alias GSMLG.Commander.Protocol.EventAck
  alias GSMLG.Commander.Protocol.JobEvent, as: WireEvent
  alias GSMLG.Repo

  @metadata_keys ~w(central_job_id artifact_id content_hash kind transfer_mode failure_code intervention_reason attempt status sequence reason code)

  def ingest(agent_id, %WireEvent{} = event, opts \\ []) do
    with :ok <- Enabled.ensure() do
      do_ingest(agent_id, event, opts)
    end
  end

  defp do_ingest(agent_id, event, opts) do
    ack_fun = Keyword.get(opts, :ack, &RPCDispatcher.ack_event/2)
    advance_limit = opts |> Keyword.get(:advance_limit, 500) |> min(1_000) |> max(1)
    max_gap = opts |> Keyword.get(:max_gap, 10_000) |> min(100_000) |> max(1)

    result =
      Repo.transaction(fn ->
        with %Job{} = job <- lock_job(event.remote_execution_id),
             :ok <- validate_agent(job, agent_id),
             :ok <- validate_identity(job, event),
             :ok <- validate_metadata(event.metadata || %{}),
             :ok <- validate_gap(job, event, max_gap),
             {:ok, inserted?} <- insert_event(job, event),
             :ok <- reject_new_terminal_event(job, event, inserted?),
             {:ok, job, applied_events} <- advance_contiguous(job, advance_limit),
             :ok <- synchronize_profile_authority(job, applied_events),
             :ok <- release_terminal_profile(job),
             :ok <- enqueue_reconcile(job, event, inserted?) do
          %{job: job, inserted?: inserted?}
        else
          nil -> Repo.rollback(:unknown_execution)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, %{job: job, inserted?: inserted?}} ->
        _ = GSMLG.Browser.finalize_job_artifacts(job.id)

        ack = %EventAck{
          protocol_version: 1,
          remote_execution_id: event.remote_execution_id,
          highest_contiguous_sequence: job.last_remote_sequence
        }

        if inserted?, do: broadcast_event(job.id, event.sequence)

        with :ok <- ack_fun.(agent_id, ack) do
          {:ok,
           %{
             inserted?: inserted?,
             highest_contiguous_sequence: job.last_remote_sequence
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp lock_job(remote_execution_id) do
    Repo.one(
      from(job in Job,
        where: job.remote_execution_id == ^remote_execution_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_agent(job, agent_id) do
    case Repo.get(Node, job.node_id) do
      %Node{commander_id: ^agent_id} -> :ok
      _other -> {:error, :agent_mismatch}
    end
  end

  defp validate_identity(job, event) do
    cond do
      event.remote_execution_id != job.remote_execution_id -> {:error, :execution_mismatch}
      event.metadata["central_job_id"] != job.id -> {:error, :job_mismatch}
      true -> :ok
    end
  end

  defp validate_metadata(metadata), do: Sanitizer.validate_metadata(metadata, @metadata_keys)

  defp insert_event(job, event) do
    existing =
      Repo.get_by(JobEvent,
        remote_execution_id: event.remote_execution_id,
        sequence: event.sequence
      )

    case existing do
      %JobEvent{job_id: job_id} when job_id == job.id ->
        if canonical_existing(existing) == canonical_wire(job, event),
          do: {:ok, false},
          else: {:error, :event_sequence_conflict}

      %JobEvent{} ->
        {:error, :event_owner_mismatch}

      nil ->
        attrs = %{
          job_id: job.id,
          remote_execution_id: event.remote_execution_id,
          sequence: event.sequence,
          event: event.event,
          phase: event.phase,
          metadata: event.metadata || %{},
          occurred_at: parse_time(event.occurred_at)
        }

        case %JobEvent{} |> JobEvent.changeset(attrs) |> Repo.insert() do
          {:ok, _event} -> {:ok, true}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  defp reject_new_terminal_event(
         %Job{status: status, result: %{"last_sequence" => last_sequence}},
         %WireEvent{sequence: sequence},
         true
       )
       when status in ~w(completed failed cancelled) and sequence <= last_sequence,
       do: :ok

  defp reject_new_terminal_event(%Job{status: status}, _event, true)
       when status in ~w(completed failed cancelled),
       do: {:error, :job_terminal}

  defp reject_new_terminal_event(_job, _event, _inserted?), do: :ok

  defp advance_contiguous(job, limit) do
    events =
      Repo.all(
        from(event in JobEvent,
          where: event.job_id == ^job.id and event.sequence > ^job.last_remote_sequence,
          order_by: [asc: event.sequence],
          limit: ^limit
        )
      )

    {contiguous, _next} =
      Enum.reduce_while(events, {[], job.last_remote_sequence + 1}, fn event, {acc, expected} ->
        if event.sequence == expected,
          do: {:cont, {[event | acc], expected + 1}},
          else: {:halt, {acc, expected}}
      end)

    contiguous = Enum.reverse(contiguous)

    with {:ok, attrs} <- transition_attrs(job, contiguous),
         {:ok, updated} <-
           job
           |> Job.transition_changeset(
             Map.put(attrs, :last_remote_sequence, job.last_remote_sequence + length(contiguous))
           )
           |> Repo.update() do
      {:ok, updated, contiguous}
    end
  end

  defp transition_attrs(job, events) do
    Enum.reduce_while(events, {:ok, %{status: job.status, phase: job.phase}}, fn event,
                                                                                 {:ok, attrs} ->
      next_status = event_status(event.event, attrs.status)

      case event_transition(attrs.status, next_status, event.event) do
        {:ok, effective_status, apply_event?} ->
          next =
            attrs
            |> Map.put(:status, effective_status)
            |> maybe_put_phase(event.phase, apply_event?)
            |> maybe_put_terminal_time(effective_status, apply_event?)
            |> maybe_put_event_error(event, apply_event?)
            |> maybe_put_remote_completion(event, job.result, apply_event?)

          {:cont, {:ok, next}}

        {:error, _reason} ->
          {:halt, {:error, :illegal_job_transition}}
      end
    end)
  end

  defp event_status("workflow.accepted", _current), do: "accepted"
  defp event_status("workflow.started", _current), do: "running"
  defp event_status("workflow.phase_changed", current), do: current
  defp event_status("intervention.required", _current), do: "waiting_human"
  defp event_status("intervention.cleared", _current), do: "running"
  defp event_status("artifact.available", _current), do: "collecting_artifacts"
  defp event_status("result.available", _current), do: "collecting_artifacts"
  defp event_status("workflow.completed", _current), do: "collecting_artifacts"
  defp event_status("workflow.failed", _current), do: "failed"
  defp event_status("workflow.cancelled", _current), do: "cancelled"

  defp event_transition(current, _next, _event)
       when current in ~w(completed failed cancelled),
       do: {:ok, current, false}

  defp event_transition(current, next, event) do
    case JobState.validate(current, next) do
      :ok ->
        {:ok, next, true}

      {:error, _reason} when event in ["workflow.accepted", "workflow.started"] ->
        if stale_progress_event?(current, next),
          do: {:ok, current, false},
          else: {:error, :illegal_job_transition}

      {:error, _reason} ->
        {:error, :illegal_job_transition}
    end
  end

  defp stale_progress_event?(current, next) do
    rank = %{"accepted" => 1, "running" => 2, "waiting_human" => 3, "collecting_artifacts" => 4}
    Map.get(rank, current, -1) > Map.get(rank, next, -1)
  end

  defp maybe_put_phase(attrs, _phase, false), do: attrs
  defp maybe_put_phase(attrs, nil, true), do: attrs
  defp maybe_put_phase(attrs, phase, true), do: Map.put(attrs, :phase, phase)

  defp put_terminal_time(attrs, status) when status in ~w(completed failed cancelled),
    do: Map.put(attrs, :completed_at, DateTime.utc_now())

  defp put_terminal_time(attrs, _status), do: attrs

  defp maybe_put_terminal_time(attrs, _status, false), do: attrs
  defp maybe_put_terminal_time(attrs, status, true), do: put_terminal_time(attrs, status)

  defp put_event_error(attrs, %JobEvent{event: "workflow.failed", metadata: metadata}),
    do:
      Map.put(attrs, :error, %{
        "code" => metadata["code"] || metadata["failure_code"] || "remote_failure"
      })

  defp put_event_error(attrs, _event), do: attrs

  defp maybe_put_event_error(attrs, _event, false), do: attrs
  defp maybe_put_event_error(attrs, event, true), do: put_event_error(attrs, event)

  defp put_remote_completion(
         attrs,
         %JobEvent{event: "workflow.completed", sequence: sequence},
         existing_result
       ) do
    safe_result =
      (existing_result || %{})
      |> Map.put("remote_completed", true)
      |> Map.put("last_sequence", sequence)

    Map.put(attrs, :result, safe_result)
  end

  defp put_remote_completion(attrs, _event, _existing_result), do: attrs

  defp maybe_put_remote_completion(attrs, _event, _existing_result, false), do: attrs

  defp maybe_put_remote_completion(attrs, event, existing_result, true),
    do: put_remote_completion(attrs, event, existing_result)

  defp parse_time(nil), do: nil

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, timestamp, 0} -> timestamp
      _invalid -> nil
    end
  end

  defp validate_gap(job, event, max_gap) do
    if event.sequence <= job.last_remote_sequence + max_gap,
      do: :ok,
      else: {:error, :event_gap_too_large}
  end

  defp release_terminal_profile(%Job{status: status, session_id: nil, profile_id: profile_id})
       when status in ~w(completed failed cancelled) do
    Repo.update_all(from(profile in Profile, where: profile.id == ^profile_id),
      set: [automation_status: "available", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp release_terminal_profile(_job), do: :ok

  defp synchronize_profile_authority(%Job{profile_id: profile_id}, applied_events) do
    target_status =
      applied_events
      |> Enum.reverse()
      |> Enum.find_value(fn
        %JobEvent{event: "intervention.required"} -> "manual"
        %JobEvent{event: "intervention.cleared"} -> "leased"
        _event -> nil
      end)

    synchronize_profile_authority(profile_id, target_status)
  end

  defp synchronize_profile_authority(_profile_id, nil), do: :ok

  defp synchronize_profile_authority(profile_id, target_status) do
    profile =
      Repo.one(from(item in Profile, where: item.id == ^profile_id, lock: "FOR UPDATE"))

    case profile do
      %Profile{automation_status: current} = profile when current in ["leased", "manual"] ->
        if current == target_status do
          :ok
        else
          case profile
               |> Profile.changeset(%{automation_status: target_status})
               |> Repo.update() do
            {:ok, _profile} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end

      %Profile{} ->
        {:error, :profile_authority_conflict}

      nil ->
        {:error, :profile_not_found}
    end
  end

  defp enqueue_reconcile(job, event, true)
       when event.event in [
              "intervention.required",
              "artifact.available",
              "result.available",
              "workflow.completed"
            ] do
    changeset =
      ReconcileWorker.new(%{
        "job_id" => job.id,
        "trigger_sequence" => event.sequence
      })

    case Oban.insert(changeset) do
      {:ok, _oban_job} -> :ok
      {:error, _changeset} -> {:error, :reconcile_enqueue_failed}
    end
  end

  defp enqueue_reconcile(_job, _event, _inserted?), do: :ok

  defp canonical_existing(event) do
    %{
      job_id: event.job_id,
      remote_execution_id: event.remote_execution_id,
      sequence: event.sequence,
      event: event.event,
      phase: event.phase,
      metadata: event.metadata,
      occurred_at: event.occurred_at
    }
  end

  defp canonical_wire(job, event) do
    %{
      job_id: job.id,
      remote_execution_id: event.remote_execution_id,
      sequence: event.sequence,
      event: event.event,
      phase: event.phase,
      metadata: event.metadata || %{},
      occurred_at: parse_time(event.occurred_at)
    }
  end

  defp broadcast_event(job_id, sequence) do
    Notifier.job_changed(job_id, :event, %{sequence: sequence})
  end
end
