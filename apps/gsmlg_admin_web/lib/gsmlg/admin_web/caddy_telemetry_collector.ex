defmodule GSMLG.AdminWeb.CaddyTelemetryCollector do
  @moduledoc """
  Bridges Caddy telemetry events to Phoenix PubSub for LiveView consumption.

  Subscribes to all [:caddy, ...] telemetry events and broadcasts them to
  GSMLG.PubSub so CaddyLive LiveViews can receive real-time updates.
  """
  use GenServer

  @topic "caddy:telemetry"
  @max_events 500

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def subscribe do
    Phoenix.PubSub.subscribe(GSMLG.PubSub, @topic)
  end

  def recent_events(count \\ 50) do
    GenServer.call(__MODULE__, {:recent, count})
  end

  @impl true
  def init(_) do
    events = [
      [:caddy, :config, :set],
      [:caddy, :config, :get],
      [:caddy, :server, :start],
      [:caddy, :server, :stop],
      [:caddy, :server, :exit],
      [:caddy, :api, :request],
      [:caddy, :api, :response],
      [:caddy, :api, :error],
      [:caddy, :config_manager, :sync_to_caddy],
      [:caddy, :config_manager, :state_changed],
      [:caddy, :config_manager, :drift_check],
      [:caddy, :config_manager, :rollback],
      [:caddy, :external, :health_check],
      [:caddy, :external, :status_changed],
      [:caddy, :metrics, :collected],
      [:caddy, :metrics, :fetch_error],
      [:caddy, :log, :info],
      [:caddy, :log, :warning],
      [:caddy, :log, :error]
    ]

    :telemetry.attach_many(
      "gsmlg-admin-caddy-collector",
      events,
      &__MODULE__.handle_event/4,
      %{pid: self()}
    )

    {:ok, %{events: :queue.new(), count: 0}}
  end

  def handle_event(event_name, measurements, metadata, %{pid: pid}) do
    entry = %{
      event: event_name,
      measurements: measurements,
      metadata: Map.drop(metadata, [:pid]),
      timestamp: DateTime.utc_now()
    }

    send(pid, {:telemetry_event, entry})
  end

  @impl true
  def handle_info({:telemetry_event, entry}, state) do
    Phoenix.PubSub.broadcast(GSMLG.PubSub, @topic, {:caddy_telemetry, entry})

    {events, count} =
      if state.count >= @max_events do
        {_, q} = :queue.out(state.events)
        {:queue.in(entry, q), @max_events}
      else
        {:queue.in(entry, state.events), state.count + 1}
      end

    {:noreply, %{state | events: events, count: count}}
  end

  @impl true
  def handle_call({:recent, count}, _from, state) do
    events =
      state.events
      |> :queue.to_list()
      |> Enum.take(-count)
      |> Enum.reverse()

    {:reply, events, state}
  end
end
