defmodule GSMLG.Commander.RPCRouter do
  @moduledoc "Routes validated capability RPC requests without owning runtime state."

  alias GSMLG.Commander.{CapabilityRegistry, RequestDedup}

  alias GSMLG.Commander.Protocol.{
    Error,
    RPCAccepted,
    RPCError,
    RPCRequest,
    RPCResponse
  }

  @protocol_version 1
  @default_invocation_timeout_ms 30_000
  @browser_action_invocation_timeout_ms 125_000
  @mutation_operations ~w(profile.launch profile.stop session.open session.act session.close)

  @doc false
  def admission_result(%RPCRequest{} = request, result) do
    with {:ok, _deadline} <- validate_deadline(request) do
      result
      |> normalize_admission_result(request)
      |> result_tuple()
    end
  end

  @doc false
  def task_failure(%RPCRequest{} = request) do
    request
    |> task_failure_result()
    |> normalize_result(request)
    |> result_tuple()
  end

  def route(%RPCRequest{} = request, opts \\ []) do
    registry = Keyword.get(opts, :registry, CapabilityRegistry)
    dedup = Keyword.get(opts, :request_dedup, RequestDedup)

    with {:ok, invocation_deadline} <- validate_deadline(request),
         {:ok, {descriptor, handler}} <- fetch_capability(registry, request),
         :ok <- validate_descriptor(descriptor, request),
         :execute <- RequestDedup.claim(dedup, request) do
      result =
        handler
        |> invoke_before_deadline(request, invocation_deadline)
        |> normalize_result(request)

      :ok = RequestDedup.complete(dedup, request, result)
      result_tuple(result)
    else
      {:replay, result} ->
        result |> recorrelate(request.request_id) |> result_tuple()

      {:in_progress, request_id} ->
        rpc_error(request, "request_in_progress", true, %{"request_id" => request_id})

      {:error, %RPCError{} = error} ->
        {:error, error}

      {:error, %Error{} = error} ->
        rpc_error(request, error.code, false, error.details)

      {:error, reason} when is_atom(reason) ->
        rpc_error(request, Atom.to_string(reason), false, %{})
    end
  end

  defp fetch_capability(registry, request) do
    case CapabilityRegistry.fetch(registry, request.capability) do
      {:ok, capability} ->
        {:ok, capability}

      {:error, :capability_not_registered} ->
        rpc_error(request, "capability_not_supported", false, %{})
    end
  end

  defp validate_descriptor(descriptor, request) do
    cond do
      descriptor.version != request.capability_version ->
        rpc_error(request, "capability_version_not_supported", false, %{})

      request.operation not in descriptor.operations ->
        rpc_error(request, "operation_not_advertised", false, %{})

      true ->
        :ok
    end
  end

  defp validate_deadline(request) do
    with {:ok, deadline, _offset} <- DateTime.from_iso8601(request.deadline_at) do
      remaining_ms = DateTime.diff(deadline, DateTime.utc_now(), :millisecond)

      if remaining_ms > 0,
        do: {:ok, System.monotonic_time(:millisecond) + remaining_ms},
        else: rpc_error(request, "deadline_exceeded", false, %{})
    else
      {:error, _reason} -> rpc_error(request, "invalid_deadline", false, %{})
    end
  end

  defp invoke(handler, request, timeout) when is_function(handler, 1) do
    invoke_isolated(fn -> handler.(request) end, request, timeout)
  end

  defp invoke(handler, request, timeout) when is_atom(handler) do
    if function_exported?(handler, :handle_rpc, 1),
      do: invoke_isolated(fn -> handler.handle_rpc(request) end, request, timeout),
      else: {:error, %{class: "capability", code: "invalid_handler"}}
  end

  defp invoke(handler, request, timeout) when is_pid(handler),
    do: GenServer.call(handler, {:rpc, request}, timeout)

  defp invoke(_handler, _request, _timeout),
    do: {:error, %{class: "capability", code: "invalid_handler"}}

  defp invoke_isolated(fun, request, timeout) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            _exception -> handler_failure()
          catch
            _kind, _reason -> handler_failure()
          end

        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        handler_failure()
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        handler_timeout(request)
    end
  end

  defp invoke_safely(handler, request, timeout) do
    invoke(handler, request, timeout)
  rescue
    _exception -> handler_failure()
  catch
    :exit, {:timeout, _call} -> handler_timeout(request)
    _kind, _reason -> handler_failure()
  end

  defp invoke_before_deadline(handler, request, deadline) do
    case invocation_timeout(request, deadline) do
      {:ok, timeout} -> invoke_safely(handler, request, timeout)
      :expired -> deadline_exceeded()
    end
  end

  defp invocation_timeout(request, deadline) do
    case deadline - System.monotonic_time(:millisecond) do
      remaining_ms when remaining_ms > 0 ->
        {:ok, min(remaining_ms, operation_timeout(request.operation))}

      _expired ->
        :expired
    end
  end

  defp operation_timeout("session.act"), do: @browser_action_invocation_timeout_ms
  defp operation_timeout(_operation), do: @default_invocation_timeout_ms

  defp handler_timeout(%{operation: operation}) when operation in @mutation_operations do
    {:error,
     %{
       class: "capability",
       code: "operation_outcome_unknown",
       message: "Operation outcome unknown",
       retryable: false,
       human_action: "reconcile",
       details: %{}
     }}
  end

  defp handler_timeout(_request) do
    {:error,
     %{
       class: "capability",
       code: "capability_handler_timeout",
       message: "Capability handler timed out",
       retryable: true,
       details: %{}
     }}
  end

  defp handler_failure do
    {:error,
     %{
       class: "capability",
       code: "capability_handler_failed",
       message: "Capability handler failed",
       retryable: true,
       details: %{}
     }}
  end

  defp task_failure_result(%{operation: operation}) when operation in @mutation_operations,
    do: handler_timeout(%{operation: operation})

  defp task_failure_result(_request), do: handler_failure()

  defp deadline_exceeded do
    {:error,
     %{
       class: "capability",
       code: "deadline_exceeded",
       message: "Deadline exceeded",
       retryable: false,
       details: %{}
     }}
  end

  defp normalize_result({:ok, result}, request) when is_map(result) do
    %RPCResponse{
      protocol_version: @protocol_version,
      request_id: request.request_id,
      result: result
    }
  end

  defp normalize_result({:accepted, remote_execution_id}, request) do
    %RPCAccepted{
      protocol_version: @protocol_version,
      request_id: request.request_id,
      remote_execution_id: remote_execution_id
    }
  end

  defp normalize_result({:error, details}, request) when is_map(details) do
    %RPCError{
      protocol_version: @protocol_version,
      request_id: request.request_id,
      class: string_value(details, :class, "capability"),
      code: string_value(details, :code, "operation_failed"),
      message: string_value(details, :message, "Capability operation failed"),
      retryable: Map.get(details, :retryable, Map.get(details, "retryable", false)),
      human_action: string_value(details, :human_action, "none"),
      details: safe_details(details)
    }
  end

  defp normalize_result(_invalid, request) do
    elem(rpc_error(request, "invalid_handler_result", false, %{}), 1)
  end

  defp normalize_admission_result({:replay, result}, request),
    do: recorrelate(result, request.request_id)

  defp normalize_admission_result({:in_progress, request_id}, request),
    do: elem(rpc_error(request, "request_in_progress", true, %{"request_id" => request_id}), 1)

  defp normalize_admission_result({:error, reason}, request) when is_atom(reason),
    do: elem(rpc_error(request, Atom.to_string(reason), false, %{}), 1)

  defp normalize_admission_result({:overloaded, max_in_flight}, request) do
    elem(rpc_error(request, "overloaded", true, %{"max_in_flight" => max_in_flight}), 1)
  end

  defp result_tuple(%RPCError{} = error), do: {:error, error}
  defp result_tuple(result), do: {:ok, result}

  defp recorrelate(%RPCResponse{} = response, request_id),
    do: %{response | request_id: request_id}

  defp recorrelate(%RPCAccepted{} = accepted, request_id),
    do: %{accepted | request_id: request_id}

  defp recorrelate(%RPCError{} = error, request_id), do: %{error | request_id: request_id}

  defp rpc_error(request, code, retryable, details) do
    {:error,
     %RPCError{
       protocol_version: @protocol_version,
       request_id: request.request_id,
       class: "capability",
       code: code,
       message: humanize(code),
       retryable: retryable,
       human_action: "none",
       details: details
     }}
  end

  defp string_value(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp safe_details(details) do
    details
    |> Map.get(:details, Map.get(details, "details", %{}))
    |> case do
      value when is_map(value) -> value
      _invalid -> %{}
    end
  end

  defp humanize(code), do: code |> String.replace("_", " ") |> String.capitalize()
end
