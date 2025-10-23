defmodule GSMLG.Telemetry.Reporter do
  @moduledoc """
  Metrics reporter for GSMLG telemetry system.

  This module collects metrics from telemetry events and provides
  reporting capabilities to various outputs and systems.
  """

  use GenServer
  require Logger

  alias GSMLG.Telemetry.Metrics

  defstruct [:reporters, :config, :buffer]

  @doc """
  Start the metrics reporter.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry) |> Keyword.merge(opts)
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  @doc """
  Handle a telemetry event for metrics reporting.
  """
  @spec handle_event([atom()], map(), map()) :: :ok
  def handle_event(event_name, measurements, metadata) do
    GenServer.cast(__MODULE__, {:handle_event, event_name, measurements, metadata})
  end

  @doc """
  Get the current metrics report.
  """
  @spec get_report() :: map()
  def get_report do
    GenServer.call(__MODULE__, :get_report)
  end

  @doc """
  Get a summary of metrics for a specific time period.
  """
  @spec get_summary(DateTime.t(), DateTime.t()) :: map()
  def get_summary(start_time, end_time \\ DateTime.utc_now()) do
    GenServer.call(__MODULE__, {:get_summary, start_time, end_time})
  end

  @doc """
  Force generation of a metrics report.
  """
  @spec generate_report() :: :ok
  def generate_report do
    GenServer.cast(__MODULE__, :generate_report)
  end

  @doc """
  Add a custom reporter.
  """
  @spec add_reporter(atom(), module(), keyword()) :: :ok
  def add_reporter(name, reporter_module, opts \\ []) do
    GenServer.call(__MODULE__, {:add_reporter, name, reporter_module, opts})
  end

  @doc """
  Remove a reporter.
  """
  @spec remove_reporter(atom()) :: :ok
  def remove_reporter(name) do
    GenServer.call(__MODULE__, {:remove_reporter, name})
  end

  @impl true
  def init(config) do
    # Initialize reporters
    reporters = initialize_reporters(config)

    # Initialize buffer for batching events
    buffer =
      :ets.new(:gsmlg_telemetry_reporter_buffer, [
        :duplicate_bag,
        :public,
        {:read_concurrency, true},
        {:write_concurrency, true}
      ])

    # Schedule periodic reporting
    schedule_report(config)

    state = %__MODULE__{
      reporters: reporters,
      config: config,
      buffer: buffer
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_event, event_name, measurements, metadata}, state) do
    # Buffer the event for batch processing
    buffer_event(state.buffer, event_name, measurements, metadata)

    # Check if we should flush the buffer
    buffer_size = :ets.info(state.buffer, :size)
    max_buffer_size = Keyword.get(state.config, :max_buffer_size, 1000)

    if buffer_size >= max_buffer_size do
      flush_buffer(state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast(:generate_report, state) do
    flush_buffer(state)
    generate_metrics_report(state)
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_report, _from, state) do
    report = build_current_report(state)
    {:reply, report, state}
  end

  @impl true
  def handle_call({:get_summary, start_time, end_time}, _from, state) do
    summary = build_time_period_summary(state, start_time, end_time)
    {:reply, summary, state}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      buffer_size: :ets.info(state.buffer, :size),
      buffer_memory: :ets.info(state.buffer, :memory),
      active_reporters: map_size(state.reporters),
      reporters:
        Enum.map(state.reporters, fn {name, info} ->
          {name,
           %{
             module: info.module,
             pid: info.pid,
             opts: info.opts
           }}
        end)
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call({:add_reporter, name, reporter_module, opts}, _from, state) do
    case start_reporter(name, reporter_module, opts) do
      {:ok, pid} ->
        updated_reporters =
          Map.put(state.reporters, name, %{
            module: reporter_module,
            pid: pid,
            opts: opts
          })

        new_state = %{state | reporters: updated_reporters}
        {:reply, :ok, new_state}

      {:error, reason} ->
        Logger.error("Failed to start reporter #{name}: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:remove_reporter, name}, _from, state) do
    case Map.get(state.reporters, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      %{pid: pid} ->
        GenServer.stop(pid, :normal)
        updated_reporters = Map.delete(state.reporters, name)
        new_state = %{state | reporters: updated_reporters}
        {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_info(:generate_periodic_report, state) do
    flush_buffer(state)
    generate_metrics_report(state)

    # Schedule next report
    schedule_report(state.config)

    {:noreply, state}
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    # Handle reporter crashes
    case find_reporter_by_pid(state.reporters, pid) do
      {name, reporter_info} ->
        Logger.warning("Reporter #{name} crashed: #{inspect(reason)}, attempting restart...")

        case start_reporter(name, reporter_info.module, reporter_info.opts) do
          {:ok, new_pid} ->
            updated_reporters =
              Map.put(state.reporters, name, %{
                reporter_info
                | pid: new_pid
              })

            Logger.info("Reporter #{name} restarted successfully")
            {:noreply, %{state | reporters: updated_reporters}}

          {:error, restart_reason} ->
            Logger.error("Failed to restart reporter #{name}: #{inspect(restart_reason)}")
            {:noreply, state}
        end

      nil ->
        Logger.warning("Unknown process crashed: #{inspect(pid)}")
        {:noreply, state}
    end
  end

  defp initialize_reporters(config) do
    reporters_config = Keyword.get(config, :reporters, %{})

    Enum.reduce(reporters_config, %{}, fn {name, reporter_config}, acc ->
      reporter_module = Keyword.get(reporter_config, :module)
      reporter_opts = Keyword.get(reporter_config, :opts, [])

      case start_reporter(name, reporter_module, reporter_opts) do
        {:ok, pid} ->
          Map.put(acc, name, %{
            module: reporter_module,
            pid: pid,
            opts: reporter_opts
          })

        {:error, reason} ->
          Logger.error("Failed to start reporter #{name}: #{inspect(reason)}")
          acc
      end
    end)
  end

  defp start_reporter(name, reporter_module, opts) do
    if Code.ensure_loaded?(reporter_module) and
         function_exported?(reporter_module, :start_link, 1) do
      reporter_opts = Keyword.put(opts, :name, name)
      GenServer.start_link(reporter_module, reporter_opts)
    else
      {:error, :invalid_reporter_module}
    end
  end

  defp buffer_event(buffer, event_name, measurements, metadata) do
    timestamp = System.system_time(:millisecond)

    event_data = {
      event_name,
      measurements,
      metadata,
      timestamp
    }

    :ets.insert(buffer, event_data)
  end

  defp flush_buffer(state) do
    events = :ets.tab2list(state.buffer)
    :ets.delete_all_objects(state.buffer)

    # Group events by type for efficient processing
    grouped_events = Enum.group_by(events, fn {event_name, _, _, _} -> event_name end)

    # Process each group
    Enum.each(grouped_events, fn {event_name, event_list} ->
      process_event_group(state, event_name, event_list)
    end)
  end

  defp process_event_group(state, event_name, events) do
    # Calculate aggregate metrics for this event type
    aggregates = calculate_aggregates(event_name, events)

    # Forward to all reporters
    Enum.each(state.reporters, fn {_name, reporter_info} ->
      forward_to_reporter(reporter_info, event_name, aggregates, events)
    end)
  end

  defp calculate_aggregates(event_name, events) do
    measurements = Enum.map(events, fn {_, measurements, _, _} -> measurements end)
    timestamps = Enum.map(events, fn {_, _, _, timestamp} -> timestamp end)

    # Calculate basic aggregates
    count = length(events)
    first_timestamp = Enum.min(timestamps)
    last_timestamp = Enum.max(timestamps)
    duration_ms = last_timestamp - first_timestamp

    # Aggregate numeric measurements
    numeric_aggregates = aggregate_numeric_measurements(measurements)

    %{
      event_name: event_name,
      count: count,
      duration_ms: duration_ms,
      first_timestamp: first_timestamp,
      last_timestamp: last_timestamp,
      aggregates: numeric_aggregates
    }
  end

  defp aggregate_numeric_measurements(measurements) do
    # Extract all numeric measurement keys
    all_keys =
      measurements
      |> Enum.flat_map(&Map.keys/1)
      |> Enum.uniq()

    Enum.reduce(all_keys, %{}, fn key, acc ->
      values =
        Enum.flat_map(measurements, fn measurement ->
          case Map.get(measurement, key) do
            value when is_number(value) -> [value]
            _ -> []
          end
        end)

      if length(values) > 0 do
        Map.put(acc, key, %{
          count: length(values),
          sum: Enum.sum(values),
          min: Enum.min(values),
          max: Enum.max(values),
          avg: Enum.sum(values) / length(values)
        })
      else
        acc
      end
    end)
  end

  defp forward_to_reporter(reporter_info, event_name, aggregates, raw_events) do
    if function_exported?(reporter_info.module, :handle_metrics, 3) do
      try do
        reporter_info.module.handle_metrics(event_name, aggregates, raw_events)
      rescue
        error ->
          Logger.error("Reporter #{inspect(reporter_info.module)} failed: #{inspect(error)}")
      catch
        kind, value ->
          Logger.error(
            "Reporter #{inspect(reporter_info.module)} crashed: #{inspect({kind, value})}"
          )
      end
    end
  end

  defp generate_metrics_report(state) do
    report = build_current_report(state)

    # Forward report to all reporters
    Enum.each(state.reporters, fn {_name, reporter_info} ->
      if function_exported?(reporter_info.module, :handle_report, 1) do
        try do
          reporter_info.module.handle_report(report)
        rescue
          error ->
            Logger.error(
              "Reporter #{inspect(reporter_info.module)} report failed: #{inspect(error)}"
            )
        catch
          kind, value ->
            Logger.error(
              "Reporter #{inspect(reporter_info.module)} report crashed: #{inspect({kind, value})}"
            )
        end
      end
    end)

    # Log summary
    Logger.info("Generated metrics report: #{report.total_events} events")
  end

  defp build_current_report(state) do
    # Get current metrics from the Metrics module
    current_metrics = Metrics.get_summary()

    # Get recent events from buffer
    buffer_events = :ets.tab2list(state.buffer)

    %{
      timestamp: DateTime.utc_now(),
      total_events: current_metrics.total_events + length(buffer_events),
      top_events: current_metrics.top_events,
      error_rates: current_metrics.error_rates,
      average_durations: current_metrics.average_durations,
      recent_activity: current_metrics.recent_activity,
      buffer_size: length(buffer_events),
      active_reporters: map_size(state.reporters)
    }
  end

  defp build_time_period_summary(state, start_time, end_time) do
    # This would typically query historical data
    # For now, return current metrics as an approximation
    build_current_report(state)
    |> Map.put(:period_start, start_time)
    |> Map.put(:period_end, end_time)
  end

  defp find_reporter_by_pid(reporters, pid) do
    Enum.find(reporters, fn {_name, reporter_info} ->
      reporter_info.pid == pid
    end)
  end

  defp schedule_report(config) do
    # 1 minute default
    interval = Keyword.get(config, :report_interval, 60_000)

    Process.send_after(self(), :generate_periodic_report, interval)
  end

  @doc """
  Get statistics about the reporter itself.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end
end
