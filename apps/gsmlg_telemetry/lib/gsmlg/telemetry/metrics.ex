defmodule GSMLG.Telemetry.Metrics do
  @moduledoc """
  Metrics collection and aggregation for GSMLG applications.

  This module provides functionality to collect, store, and aggregate
  telemetry metrics across the application.
  """

  use GenServer
  require Logger
  alias Telemetry.Metrics

  defp default_metrics do
    [
      # Phoenix metrics
      Metrics.distribution("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.distribution("phoenix.router_dispatch.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.counter("phoenix.router_dispatch.stop.count"),
      Metrics.sum("phoenix.router_dispatch.stop.duration", unit: {:native, :millisecond}),
      Metrics.last_value("phoenix.endpoint.stop.system_time"),
      Metrics.last_value("phoenix.router_dispatch.stop.system_time"),

      # LiveView metrics
      Metrics.distribution("phoenix.live_view.mount.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.distribution("phoenix.live_view.handle_params.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.counter("phoenix.live_view.mount.stop.count"),
      Metrics.counter("phoenix.live_view.handle_params.stop.count"),

      # Database metrics
      Metrics.distribution("ecto.repo.query.total_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.distribution("ecto.repo.query.decode_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      Metrics.distribution("ecto.repo.query.query_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      Metrics.distribution("ecto.repo.query.queue_time",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
      ),
      Metrics.counter("ecto.repo.query.count"),
      Metrics.sum("ecto.repo.query.total_time", unit: {:native, :millisecond}),

      # VM metrics
      Metrics.last_value("vm.memory.total", unit: :byte),
      Metrics.last_value("vm.memory.processes", unit: :byte),
      Metrics.last_value("vm.memory.processes_used", unit: :byte),
      Metrics.last_value("vm.memory.system", unit: :byte),
      Metrics.last_value("vm.memory.atom", unit: :byte),
      Metrics.last_value("vm.memory.atom_used", unit: :byte),
      Metrics.last_value("vm.memory.binary", unit: :byte),
      Metrics.last_value("vm.memory.code", unit: :byte),
      Metrics.last_value("vm.memory.ets", unit: :byte),
      Metrics.last_value("vm.total_run_queue_lengths.total"),
      Metrics.last_value("vm.total_run_queue_lengths.cpu"),
      Metrics.last_value("vm.total_run_queue_lengths.io"),
      Metrics.last_value("vm.system_counts.process_count"),
      Metrics.last_value("vm.system_counts.atom_count"),
      Metrics.last_value("vm.system_counts.port_count"),

      # Application-specific metrics
      Metrics.distribution("gsmlg.web.request.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.counter("gsmlg.web.request.count"),
      Metrics.counter("gsmlg.web.request.error_count"),
      Metrics.last_value("gsmlg.web.request.status"),
      Metrics.distribution("gsmlg.repo.query.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]]
      ),
      Metrics.counter("gsmlg.repo.query.count"),
      Metrics.counter("gsmlg.repo.query.error_count"),
      Metrics.sum("gsmlg.repo.query.duration", unit: {:native, :millisecond}),

      # Custom business metrics
      Metrics.counter("gsmlg.user.login.count"),
      Metrics.counter("gsmlg.user.logout.count"),
      Metrics.counter("gsmlg.user.register.count"),
      Metrics.distribution("gsmlg.cache.hit.duration", unit: {:native, :millisecond}),
      Metrics.counter("gsmlg.cache.hit.count"),
      Metrics.counter("gsmlg.cache.miss.count"),
      Metrics.distribution("gsmlg.external_api.request.duration", unit: {:native, :millisecond}),
      Metrics.counter("gsmlg.external_api.request.count"),
      Metrics.counter("gsmlg.external_api.error.count")
    ]
  end

  defstruct [:metrics, :ets_table, :config]

  @doc """
  Start the metrics collector.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry) |> Keyword.merge(opts)
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Record a telemetry event.
  """
  @spec record_event([atom()], map(), map()) :: :ok
  def record_event(event_name, measurements, metadata) do
    GenServer.cast(__MODULE__, {:record_event, event_name, measurements, metadata})
  end

  @doc """
  Get all current metrics.
  """
  @spec get_metrics() :: [map()]
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Get metrics for a specific event name.
  """
  @spec get_metrics([atom()]) :: [map()]
  def get_metrics(event_name) do
    GenServer.call(__MODULE__, {:get_metrics, event_name})
  end

  @doc """
  Reset all metrics.
  """
  @spec reset_metrics() :: :ok
  def reset_metrics do
    GenServer.cast(__MODULE__, :reset_metrics)
  end

  @doc """
  Get metrics summary (aggregated values).
  """
  @spec get_summary() :: map()
  def get_summary do
    GenServer.call(__MODULE__, :get_summary)
  end

  @impl true
  def init(config) do
    # Create ETS table for storing metrics
    ets_table =
      :ets.new(:gsmlg_telemetry_metrics, [
        :set,
        :public,
        :named_table,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Initialize metrics
    metrics = initialize_metrics(config)

    {:ok, %__MODULE__{metrics: metrics, ets_table: ets_table, config: config}}
  end

  @impl true
  def handle_cast({:record_event, event_name, measurements, metadata}, state) do
    store_event_metrics(event_name, measurements, metadata, state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:reset_metrics, state) do
    :ets.delete_all_objects(state.ets_table)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, state) do
    metrics = :ets.tab2list(state.ets_table)
    {:reply, metrics, state}
  end

  @impl true
  def handle_call({:get_metrics, event_name}, _from, state) do
    pattern = {{event_name, :_}, :_}

    metrics =
      :ets.select(state.ets_table, [{pattern, [], [[{:element, 1, :"$_"}, {:element, 2, :"$_"}]]}])

    {:reply, metrics, state}
  end

  @impl true
  def handle_call(:get_summary, _from, state) do
    summary = calculate_summary(state)
    {:reply, summary, state}
  end

  @impl true
  def handle_call(:get_configured_metrics, _from, state) do
    {:reply, state.metrics, state}
  end

  defp initialize_metrics(config) do
    custom_metrics = Keyword.get(config, :metrics, default_metrics())

    Enum.map(custom_metrics, fn metric ->
      case metric do
        name when is_atom(name) or is_list(name) ->
          create_metric_from_name(name)

        %{__struct__: Telemetry.Metrics.Counter} = metric ->
          metric

        %{__struct__: Telemetry.Metrics.Distribution} = metric ->
          metric

        %{__struct__: Telemetry.Metrics.LastValue} = metric ->
          metric

        %{__struct__: Telemetry.Metrics.Sum} = metric ->
          metric

        %{__struct__: Telemetry.Metrics.Summary} = metric ->
          metric

        _ ->
          Logger.warning("Invalid metric definition: #{inspect(metric)}")
          nil
      end
    end)
    |> Enum.filter(& &1)
  end

  defp create_metric_from_name(name) do
    # Try to infer metric type from name
    last_name = List.last(name)
    last_name_str = Atom.to_string(last_name)

    cond do
      String.contains?(last_name_str, "duration") ->
        distribution(name, unit: {:native, :millisecond})

      String.contains?(last_name_str, "count") ->
        counter(name)

      String.contains?(last_name_str, "total") ->
        sum(name)

      true ->
        last_value(name)
    end
  end

  defp store_event_metrics(event_name, measurements, metadata, state) do
    timestamp = System.system_time(:millisecond)
    event_key = {event_name, timestamp}

    # Store raw event data
    event_data = %{
      event_name: event_name,
      measurements: measurements,
      metadata: metadata,
      timestamp: timestamp
    }

    :ets.insert(state.ets_table, {event_key, event_data})

    # Update aggregated metrics
    update_aggregated_metrics(event_name, measurements, metadata, state)
  end

  defp update_aggregated_metrics(event_name, measurements, metadata, state) do
    # Count events
    count_key = {:count, event_name}
    current_count = :ets.lookup_element(state.ets_table, count_key, 2, 0)
    :ets.insert(state.ets_table, {count_key, current_count + 1})

    # Sum duration measurements
    Enum.each(measurements, fn
      {key, value} when is_number(value) ->
        if String.contains?(Atom.to_string(key), "duration") or
             String.contains?(Atom.to_string(key), "time") do
          sum_key = {:sum, event_name, key}
          current_sum = :ets.lookup_element(state.ets_table, sum_key, 2, 0)
          :ets.insert(state.ets_table, {sum_key, current_sum + value})
        end

      _ ->
        :ok
    end)

    # Track last values
    Enum.each(measurements, fn {key, value} ->
      last_key = {:last, event_name, key}

      :ets.insert(
        state.ets_table,
        {last_key, %{value: value, timestamp: System.system_time(:millisecond)}}
      )
    end)

    # Track error counts
    if metadata[:status] == :error or metadata[:kind] do
      error_key = {:error_count, event_name}
      current_error_count = :ets.lookup_element(state.ets_table, error_key, 2, 0)
      :ets.insert(state.ets_table, {error_key, current_error_count + 1})
    end
  end

  defp calculate_summary(state) do
    %{
      total_events: calculate_total_events(state),
      top_events: calculate_top_events(state),
      error_rates: calculate_error_rates(state),
      average_durations: calculate_average_durations(state),
      recent_activity: calculate_recent_activity(state)
    }
  end

  defp calculate_total_events(state) do
    count_pattern = {{:count, :_}, :_}
    counts = :ets.select(state.ets_table, [{count_pattern, [], [{:element, 2, :"$_"}]}])
    Enum.sum(counts)
  end

  defp calculate_top_events(state) do
    count_pattern = {{:count, :"$1"}, :"$2"}
    top_events = :ets.select(state.ets_table, [{count_pattern, [], [{{:"$1", :"$2"}}]}])

    Enum.sort(top_events, fn {_, count1}, {_, count2} -> count1 >= count2 end)
    |> Enum.take(10)
  end

  defp calculate_error_rates(state) do
    # Calculate error rates for each event type
    event_names = get_unique_event_names(state)

    Enum.map(event_names, fn event_name ->
      total_count = :ets.lookup_element(state.ets_table, {:count, event_name}, 2, 0)
      error_count = :ets.lookup_element(state.ets_table, {:error_count, event_name}, 2, 0)

      error_rate =
        if total_count > 0 do
          error_count / total_count * 100
        else
          0
        end

      {event_name, %{total_count: total_count, error_count: error_count, error_rate: error_rate}}
    end)
    |> Enum.sort(fn {_, %{error_rate: rate1}}, {_, %{error_rate: rate2}} -> rate1 >= rate2 end)
  end

  defp calculate_average_durations(state) do
    # Calculate average durations for events with duration measurements
    event_names = get_unique_event_names(state)

    Enum.map(event_names, fn event_name ->
      # Look for sum and count for duration measurements
      duration_sum_pattern = {{:sum, event_name, :"$1"}, :"$2"}

      duration_sums =
        :ets.select(state.ets_table, [{duration_sum_pattern, [], [{{:"$1", :"$2"}}]}])

      count = :ets.lookup_element(state.ets_table, {:count, event_name}, 2, 0)

      avg_durations =
        Enum.map(duration_sums, fn {measurement_name, sum} ->
          average = if count > 0, do: sum / count, else: 0
          {measurement_name, average}
        end)

      if length(avg_durations) > 0 do
        {event_name, avg_durations}
      end
    end)
    |> Enum.filter(& &1)
  end

  defp calculate_recent_activity(state) do
    # Get recent events from the last minute
    now = System.system_time(:millisecond)
    one_minute_ago = now - 60_000

    recent_pattern = {{:"$1", :"$2"}, :"$3"}

    recent_events =
      :ets.select(state.ets_table, [
        {
          recent_pattern,
          [{:andalso, {:is_tuple, :"$1"}, {">=", :"$2", one_minute_ago}}],
          [:"$_"]
        }
      ])

    %{
      count: length(recent_events),
      events: Enum.take(recent_events, 10)
    }
  end

  defp get_unique_event_names(state) do
    pattern = {{:"$1", :_}, :_}

    :ets.select(state.ets_table, [{pattern, [], [{{:element, 1, :"$1"}}]}])
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.filter(fn
      :count -> false
      :sum -> false
      :last -> false
      :error_count -> false
      _ -> true
    end)
  end

  # Helper functions to create metrics

  defp counter(name), do: Telemetry.Metrics.counter(name)

  defp sum(name, opts \\ []), do: Telemetry.Metrics.sum(name, opts)

  defp last_value(name, opts \\ []), do: Telemetry.Metrics.last_value(name, opts)

  defp distribution(name, opts \\ []), do: Telemetry.Metrics.distribution(name, opts)

  @doc """
  Get the configured metrics list.
  """
  @spec get_configured_metrics() :: [Telemetry.Metrics.t()]
  def get_configured_metrics do
    GenServer.call(__MODULE__, :get_configured_metrics)
  end
end
