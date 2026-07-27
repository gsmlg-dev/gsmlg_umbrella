defmodule GSMLG.AdminWeb.ProxyRulesTelemetryBridge do
  @moduledoc """
  Bridges bounded proxy-rules lifecycle telemetry into the admin PubSub.
  """

  use GenServer

  @topic "proxy_rules:status"
  @handler_id {__MODULE__, :lifecycle}
  @events [
    [:gsmlg, :proxy_rules, :status, :change],
    [:gsmlg, :proxy_rules, :artifact, :publication],
    [:gsmlg, :proxy_rules, :artifact, :restoration],
    [:gsmlg, :proxy_rules, :remote, :fetch, :exception],
    [:gsmlg, :proxy_rules, :local, :reconciliation, :failure],
    [:gsmlg, :proxy_rules, :compile, :exception],
    [:gsmlg, :proxy_rules, :recovery, :exception]
  ]
  @measurement_keys [
    :duration,
    :response_size,
    :artifact_size,
    :input_rule_count,
    :output_rule_count,
    :duplicate_count,
    :collapsed_count,
    :conflict_count,
    :invalid_count,
    :unsupported_count,
    :generation
  ]
  @metadata_keys [:source, :list, :format, :status, :failure_category, :readiness]

  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec topic() :: String.t()
  def topic, do: @topic

  @impl true
  def init(options) do
    handler_id = Keyword.get(options, :handler_id, @handler_id)

    state = %{
      handler_id: handler_id,
      pubsub: Keyword.get(options, :pubsub, GSMLG.PubSub),
      topic: Keyword.get(options, :topic, @topic),
      broadcaster: Keyword.get(options, :broadcaster, &Phoenix.PubSub.broadcast/3)
    }

    case claim_handler(handler_id) do
      :ok -> {:ok, state}
      {:error, :already_exists} -> {:stop, :telemetry_handler_already_exists}
    end
  end

  @doc false
  def handle_telemetry(_event, measurements, metadata, %{bridge: bridge}) do
    send(
      bridge,
      {:proxy_rules_telemetry, bounded_measurements(measurements), bounded_metadata(metadata)}
    )

    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  def handle_telemetry(_event, _measurements, _metadata, _invalid_config), do: :ok

  @impl true
  def handle_info({:proxy_rules_telemetry, measurements, metadata}, state) do
    message = {:proxy_rules_status_changed, measurements, metadata}
    safe_broadcast(state.broadcaster, state.pubsub, state.topic, message)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    if owns_handler?(handler_id, self()), do: :telemetry.detach(handler_id)
    :ok
  end

  defp safe_broadcast(broadcaster, pubsub, topic, message) do
    broadcaster.(pubsub, topic, message)
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp owns_handler?(handler_id, owner) do
    Enum.any?(:telemetry.list_handlers(List.first(@events)), fn
      %{id: ^handler_id, config: %{bridge: ^owner}} -> true
      _handler -> false
    end)
  end

  defp claim_handler(handler_id) do
    lock = {{__MODULE__, :handler_claim, handler_id}, self()}

    case :global.trans(lock, fn -> claim_handler_locked(handler_id) end) do
      :aborted -> {:error, :already_exists}
      result -> result
    end
  end

  defp claim_handler_locked(handler_id) do
    case registered_owner(handler_id) do
      owner when is_pid(owner) ->
        if Process.alive?(owner), do: {:error, :already_exists}, else: reclaim_handler(handler_id)

      _stale_or_missing ->
        reclaim_handler(handler_id)
    end
  end

  defp reclaim_handler(handler_id) do
    :telemetry.detach(handler_id)

    :telemetry.attach_many(
      handler_id,
      @events,
      &__MODULE__.handle_telemetry/4,
      %{bridge: self()}
    )
  end

  defp registered_owner(handler_id) do
    Enum.find_value(:telemetry.list_handlers(List.first(@events)), fn
      %{id: ^handler_id, config: %{bridge: owner}} -> owner
      %{id: ^handler_id} -> :malformed
      _handler -> nil
    end)
  end

  defp bounded_measurements(measurements) when is_map(measurements) do
    Enum.reduce(measurements, %{}, fn
      {key, value}, bounded
      when key in @measurement_keys and is_number(value) and value >= 0 ->
        Map.put(bounded, key, value)

      _other, bounded ->
        bounded
    end)
  end

  defp bounded_measurements(_measurements), do: %{}

  defp bounded_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn
      {key, value}, bounded
      when key in @metadata_keys and
             (is_atom(value) or (is_integer(value) and value >= 0)) ->
        Map.put(bounded, key, value)

      _other, bounded ->
        bounded
    end)
  end

  defp bounded_metadata(_metadata), do: %{}
end
