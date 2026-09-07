defmodule GSMLG.Browser.Telemetry do
  @moduledoc false

  alias GSMLG.Browser.{Artifact, Error}
  alias GSMLG.Commander.Protocol.RPCError

  @reconcile_event [:gsmlg, :browser, :reconcile, :complete]
  @artifact_event [:gsmlg, :browser, :artifact, :transfer]
  @artifact_statuses ~w(pending uploading verified rejected)
  @transfer_modes ~w(inline signed_upload remote_pending)
  @failure_codes ~w(
    artifact_ack_mismatch
    artifact_id_conflict
    artifact_identity_mismatch
    artifact_integrity_failed
    artifact_transfer_enqueue_failed
    artifact_upload_reset_failed
    execution_mismatch
    illegal_job_transition
    invalid_artifact
    invalid_artifact_manifest
    invalid_artifact_state
    invalid_artifact_type
    invalid_chat_url
    invalid_inline_content
    invalid_rpc_response
    job_mismatch
    job_not_bound
    node_offline
    not_found
    rpc_timeout
    service_unavailable
    stale_upload_generation
    storage_prepare_failed
  )

  def measure_reconcile(job_id, operation) when is_function(operation, 0) do
    started_at = System.monotonic_time()

    try do
      result = operation.()
      {outcome, failure_code} = outcome(result)

      emit_reconcile(started_at, job_id, outcome, failure_code)
      result
    rescue
      exception ->
        emit_reconcile(started_at, job_id, "error", "operation_failed")
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_reconcile(started_at, job_id, "error", "operation_failed")
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def measure_artifact_transfer(%Artifact{} = artifact, operation)
      when is_function(operation, 0) do
    try do
      result = operation.()
      {outcome, failure_code} = outcome(result)

      metadata =
        artifact_metadata(
          artifact,
          result_status(result, outcome),
          outcome,
          failure_code
        )

      :telemetry.execute(@artifact_event, %{count: 1}, metadata)
      result
    rescue
      exception ->
        emit_artifact_failure(artifact)
        reraise exception, __STACKTRACE__
    catch
      kind, reason ->
        emit_artifact_failure(artifact)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp emit_reconcile(started_at, job_id, outcome, failure_code) do
    :telemetry.execute(
      @reconcile_event,
      %{duration: System.monotonic_time() - started_at, count: 1},
      %{
        job_id: safe_id(job_id),
        outcome: outcome,
        failure_code: failure_code
      }
    )
  end

  defp emit_artifact_failure(artifact) do
    :telemetry.execute(
      @artifact_event,
      %{count: 1},
      artifact_metadata(artifact, "failed", "error", "operation_failed")
    )
  end

  defp artifact_metadata(artifact, status, outcome, failure_code) do
    %{
      artifact_id: safe_id(artifact.id),
      job_id: safe_id(artifact.job_id),
      transfer_mode: finite_value(artifact.transfer_mode, @transfer_modes),
      status: finite_value(status, @artifact_statuses ++ ["failed"]),
      outcome: outcome,
      failure_code: failure_code
    }
  end

  defp outcome({:ok, _value}), do: {"ok", nil}
  defp outcome(:ok), do: {"ok", nil}
  defp outcome({:error, reason}), do: {"error", failure_code(reason)}
  defp outcome(_result), do: {"error", "operation_failed"}

  defp result_status({:ok, %Artifact{status: status}}, "ok"), do: status
  defp result_status(_result, "error"), do: "failed"
  defp result_status(_result, _outcome), do: "failed"

  defp failure_code(%Error{code: code}), do: finite_value(code, @failure_codes)
  defp failure_code(%RPCError{code: code}), do: finite_value(code, @failure_codes)

  defp failure_code(reason) when is_atom(reason),
    do: finite_value(Atom.to_string(reason), @failure_codes)

  defp failure_code(_reason), do: "operation_failed"

  defp finite_value(value, allowed) do
    if Enum.member?(allowed, value), do: value, else: "operation_failed"
  end

  defp safe_id(value) when is_binary(value) and byte_size(value) <= 128 do
    if Regex.match?(~r/\A[[:alnum:]_.:-]+\z/u, value), do: value, else: "unknown"
  end

  defp safe_id(_value), do: "unknown"
end
