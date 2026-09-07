defmodule GSMLG.Browser.CommanderBridge do
  @moduledoc false

  alias GSMLG.Browser.{Job, Node, Profile, Session}
  alias GSMLG.CommandPlatform.RPCDispatcher
  alias GSMLG.Commander.Protocol.{RPCAccepted, RPCRequest, RPCResponse}

  @capability "browser.control"
  @protocol_version 1

  def start(%Job{} = job, %Node{} = node, %Profile{} = profile, opts \\ []) do
    request =
      request(
        "workflow.start",
        job.idempotency_key,
        job.deadline_at,
        %{
          "central_job_id" => job.id,
          "workflow" => job.workflow,
          "workflow_version" => job.workflow_version,
          "profile_id" => profile.external_id,
          "input" => job.input,
          "output_formats" => job.output_formats,
          "requested_by_actor_id" => job.requested_by_actor_id
        }
      )

    case dispatch(node, request, opts) do
      {:ok, %RPCAccepted{request_id: request_id} = accepted}
      when request_id == request.request_id ->
        {:ok, accepted}

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def reconcile(%Job{} = job, %Node{} = node, opts \\ []) do
    payload = %{"central_job_id" => job.id}

    payload =
      if job.remote_execution_id,
        do: Map.put(payload, "remote_execution_id", job.remote_execution_id),
        else: payload

    request =
      request("workflow.reconcile", control_key(job, "reconcile"), control_deadline(), payload)

    case dispatch(node, request, opts) do
      {:ok, %RPCResponse{request_id: request_id, result: result}}
      when request_id == request.request_id ->
        validate_identity(job, result)

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def operation(%Job{} = job, %Node{} = node, operation, idempotency_key, opts \\ []) do
    payload =
      Map.merge(Keyword.get(opts, :payload, %{}), %{
        "central_job_id" => job.id,
        "remote_execution_id" => job.remote_execution_id
      })

    request = request(operation, idempotency_key, control_deadline(), payload)

    case dispatch(node, request, opts) do
      {:ok, %RPCResponse{request_id: request_id, result: result}}
      when request_id == request.request_id ->
        validate_identity(job, result)

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def call(%Node{} = node, operation, payload, idempotency_key, deadline_at, opts \\ []) do
    request = request(operation, idempotency_key, deadline_at, payload)

    case dispatch(node, request, opts) do
      {:ok, %RPCResponse{request_id: request_id, result: result}}
      when request_id == request.request_id ->
        {:ok, result}

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def artifact_ack(owner, node, artifact, opts \\ [])

  def artifact_ack(%Job{} = job, %Node{} = node, artifact, opts) do
    deadline = DateTime.add(DateTime.utc_now(), 30, :second)

    payload = %{
      "central_job_id" => job.id,
      "remote_execution_id" => job.remote_execution_id,
      "artifact_id" => artifact.id,
      "sha256" => artifact.sha256
    }

    request =
      request(
        "artifact.ack",
        "#{job.idempotency_key}:artifact.ack:#{artifact.id}",
        deadline,
        payload
      )

    case dispatch(node, request, opts) do
      {:ok, %RPCResponse{request_id: request_id, result: result}}
      when request_id == request.request_id ->
        validate_artifact_ack(job, artifact, result)

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def artifact_ack(%Session{} = session, %Node{} = node, artifact, opts) do
    deadline = DateTime.add(DateTime.utc_now(), 30, :second)

    payload = %{
      "central_session_id" => session.id,
      "remote_session_id" => session.remote_session_id,
      "artifact_id" => artifact.id,
      "sha256" => artifact.sha256
    }

    request =
      request(
        "artifact.ack",
        "session:#{session.id}:artifact.ack:#{artifact.id}",
        deadline,
        payload
      )

    case dispatch(node, request, opts) do
      {:ok, %RPCResponse{request_id: request_id, result: result}}
      when request_id == request.request_id ->
        validate_artifact_ack(session, artifact, result)

      {:ok, _unexpected} ->
        {:error, :invalid_rpc_response}

      {:error, _reason} = error ->
        error
    end
  end

  def request(operation, idempotency_key, deadline_at, payload) do
    %RPCRequest{
      protocol_version: @protocol_version,
      request_id: Ecto.UUID.generate(),
      capability: @capability,
      capability_version: 1,
      operation: operation,
      idempotency_key: idempotency_key,
      deadline_at: DateTime.to_iso8601(deadline_at),
      payload: payload
    }
  end

  defp validate_identity(job, result) when is_map(result) do
    remote = result["remote_execution_id"]

    cond do
      result["central_job_id"] != job.id ->
        {:error, :job_mismatch}

      not is_binary(remote) ->
        {:error, :invalid_rpc_response}

      job.remote_execution_id && remote != job.remote_execution_id ->
        {:error, :execution_mismatch}

      true ->
        {:ok, result}
    end
  end

  defp validate_identity(_job, _result), do: {:error, :invalid_rpc_response}

  defp validate_artifact_ack(job, artifact, result) when is_map(result) do
    if artifact_ack_identity(job, result) and result["artifact_id"] == artifact.id and
         result["sha256"] == artifact.sha256 do
      {:ok, result}
    else
      {:error, :artifact_ack_mismatch}
    end
  end

  defp validate_artifact_ack(_job, _artifact, _result), do: {:error, :invalid_rpc_response}

  defp artifact_ack_identity(%Job{} = job, result),
    do:
      result["central_job_id"] == job.id and
        result["remote_execution_id"] == job.remote_execution_id

  defp artifact_ack_identity(%Session{} = session, result),
    do:
      result["central_session_id"] == session.id and
        result["remote_session_id"] == session.remote_session_id

  defp dispatch(node, request, opts) do
    case Keyword.fetch(opts, :dispatch) do
      {:ok, dispatch} ->
        dispatch.(request)

      :error ->
        RPCDispatcher.dispatch(node.commander_id, request,
          timeout: Keyword.get(opts, :timeout, rpc_timeout())
        )
    end
  end

  defp control_key(job, operation),
    do: Map.get(job.control_keys || %{}, operation, "#{job.idempotency_key}:#{operation}")

  defp rpc_timeout, do: Application.get_env(:gsmlg_browser, :rpc_timeout_ms, 30_000)
  defp control_deadline, do: DateTime.add(DateTime.utc_now(), rpc_timeout(), :millisecond)
end
