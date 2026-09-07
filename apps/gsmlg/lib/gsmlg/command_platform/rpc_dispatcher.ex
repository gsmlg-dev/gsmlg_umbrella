defmodule GSMLG.CommandPlatform.RPCDispatcher do
  @moduledoc "Central synchronous bridge for Commander capability RPC messages."

  alias GSMLG.CommandPlatform.{AgentRegistry, PendingRequestRegistry, ReplayCache}

  alias GSMLG.Commander.Protocol.{
    Envelope,
    EventAck,
    JobEvent,
    RPCAccepted,
    RPCError,
    RPCRequest,
    RPCResponse
  }

  @owner_ttl_ms :timer.hours(24)

  def dispatch(agent_id, %RPCRequest{} = request, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    replay_cache = Keyword.get(opts, :replay_cache, ReplayCache)

    with :ok <- claim_request_owner(agent_id, request, replay_cache) do
      case ReplayCache.fetch(replay_cache, {:rpc, request.request_id}) do
        {:ok, result} ->
          dispatch_result(result)

        :error ->
          dispatch_live(agent_id, request, timeout)
      end
    end
  end

  def route_incoming(agent_id, message), do: route_incoming(agent_id, message, [])

  def route_incoming(agent_id, %RPCAccepted{} = message, opts),
    do: route_terminal(agent_id, message, replay_cache(opts))

  def route_incoming(agent_id, %RPCResponse{} = message, opts),
    do: route_terminal(agent_id, message, replay_cache(opts))

  def route_incoming(agent_id, %RPCError{} = message, opts),
    do: route_terminal(agent_id, message, replay_cache(opts))

  def route_incoming(agent_id, %JobEvent{} = event, opts) do
    cache = replay_cache(opts)
    key = {:execution_owner, event.remote_execution_id}

    case ReplayCache.fetch(cache, key) do
      {:ok, %{agent_id: ^agent_id}} ->
        with :ok <- ReplayCache.refresh(cache, key, @owner_ttl_ms) do
          Phoenix.PubSub.broadcast(
            GSMLG.PubSub,
            "commander:events",
            {:commander_job_event, agent_id, event}
          )
        end

      {:ok, _other} ->
        {:error, :agent_mismatch}

      :error ->
        {:error, :unknown_execution}
    end
  end

  defp route_terminal(agent_id, message, replay_cache) do
    case ReplayCache.fetch(replay_cache, {:rpc_owner, message.request_id}) do
      {:ok, %{agent_id: ^agent_id} = owner} ->
        with :ok <- bind_execution_owner(message, owner, replay_cache),
             :ok <- ReplayCache.put(replay_cache, {:rpc, message.request_id}, message) do
          PendingRequestRegistry.complete(message.request_id, message)
        end

      {:ok, _other_agent} ->
        {:error, :agent_mismatch}

      :error ->
        {:error, :unknown_request}
    end
  end

  def ack_event(agent_id, ack), do: ack_event(agent_id, ack, [])

  def ack_event(agent_id, %EventAck{} = ack, opts) do
    cache = replay_cache(opts)
    key = {:execution_owner, ack.remote_execution_id}

    with {:ok, %{agent_id: ^agent_id}} <-
           ReplayCache.fetch(cache, key),
         :ok <- ReplayCache.refresh(cache, key, @owner_ttl_ms),
         {:ok, wire} <- Envelope.encode(ack) do
      AgentRegistry.send_to_agent(agent_id, {:commander_event_ack, wire})
    else
      {:ok, _other} -> {:error, :agent_mismatch}
      :error -> {:error, :unknown_execution}
      {:error, _reason} = error -> error
    end
  end

  def replay_pending(agent_id) do
    PendingRequestRegistry.pending_for_agent(agent_id)
    |> Enum.reduce_while(:ok, fn %{wire: wire}, :ok ->
      case AgentRegistry.send_to_agent(agent_id, {:commander_rpc, wire}) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc "Re-establishes the authoritative owner for a durable execution after central restart."
  def register_execution_owner(agent_id, remote_execution_id, opts \\ [])
      when is_binary(agent_id) and is_binary(remote_execution_id) do
    cache = replay_cache(opts)
    owner = %{agent_id: agent_id, capability: "browser.control"}

    case ReplayCache.put_if_absent(
           cache,
           {:execution_owner, remote_execution_id},
           owner,
           @owner_ttl_ms
         ) do
      :ok ->
        :ok

      {:exists, ^owner} ->
        ReplayCache.refresh(cache, {:execution_owner, remote_execution_id}, @owner_ttl_ms)

      {:exists, _other} ->
        {:error, :execution_owner_mismatch}

      {:error, :capacity_reached} ->
        {:error, :ownership_capacity_reached}
    end
  end

  defp dispatch_live(agent_id, request, timeout) do
    with {:ok, wire} <- Envelope.encode(request),
         :ok <-
           PendingRequestRegistry.register_request(
             agent_id,
             request,
             wire,
             self(),
             timeout
           ),
         :ok <- AgentRegistry.send_to_agent(agent_id, {:commander_rpc, wire}) do
      await_result(request.request_id, timeout + 100)
    else
      {:error, :already_pending} ->
        {:error, :request_in_progress}

      {:error, reason} = error ->
        PendingRequestRegistry.cancel(request.request_id)
        if reason == :agent_not_found, do: {:error, :node_offline}, else: error
    end
  end

  defp claim_request_owner(agent_id, request, replay_cache) do
    owner = %{agent_id: agent_id, capability: request.capability}

    case ReplayCache.put_if_absent(
           replay_cache,
           {:rpc_owner, request.request_id},
           owner,
           @owner_ttl_ms
         ) do
      :ok -> :ok
      {:exists, ^owner} -> :ok
      {:exists, _other_agent} -> {:error, :agent_mismatch}
      {:error, :capacity_reached} -> {:error, :ownership_capacity_reached}
    end
  end

  defp bind_execution_owner(%RPCAccepted{} = message, owner, replay_cache) do
    case ReplayCache.put_if_absent(
           replay_cache,
           {:execution_owner, message.remote_execution_id},
           owner,
           @owner_ttl_ms
         ) do
      :ok -> :ok
      {:exists, ^owner} -> :ok
      {:exists, _other} -> {:error, :execution_owner_mismatch}
      {:error, :capacity_reached} -> {:error, :ownership_capacity_reached}
    end
  end

  defp bind_execution_owner(_terminal, _owner, _replay_cache), do: :ok

  defp await_result(request_id, receive_timeout) do
    receive do
      {:commander_rpc_result, ^request_id, result} -> dispatch_result(result)
      {:commander_rpc_timeout, ^request_id} -> {:error, :rpc_timeout}
    after
      receive_timeout ->
        PendingRequestRegistry.cancel(request_id)
        {:error, :rpc_timeout}
    end
  end

  defp dispatch_result(%RPCError{} = error), do: {:error, error}
  defp dispatch_result(%RPCAccepted{} = accepted), do: {:ok, accepted}
  defp dispatch_result(%RPCResponse{} = response), do: {:ok, response}

  defp replay_cache(opts), do: Keyword.get(opts, :replay_cache, ReplayCache)
end
