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

    config = %{
      pubsub: Keyword.get(options, :pubsub, GSMLG.PubSub),
      topic: Keyword.get(options, :topic, @topic)
    }

    case :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_telemetry/4, config) do
      :ok -> {:ok, %{handler_id: handler_id}}
      {:error, :already_exists} -> {:stop, :telemetry_handler_already_exists}
    end
  end

  @doc false
  def handle_telemetry(_event, measurements, metadata, config) do
    Phoenix.PubSub.broadcast(
      config.pubsub,
      config.topic,
      {:proxy_rules_status_changed, bounded_measurements(measurements),
       bounded_metadata(metadata)}
    )
  end

  @impl true
  def terminate(_reason, %{handler_id: handler_id}) do
    :telemetry.detach(handler_id)
    :ok
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
