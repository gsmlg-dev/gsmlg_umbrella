defmodule GSMLG.Telemetry.Backends.Console do
  @moduledoc """
  Console backend for GSMLG telemetry system.

  This backend outputs telemetry events to the console with
  configurable formatting and filtering options.
  """

  use GenServer
  require Logger

  @default_colors %{
    debug: :cyan,
    info: :normal,
    warn: :yellow,
    error: :red
  }

  @default_format "%{time} %{level} [%{metadata}] %{message}"

  defstruct [:config, :colors, :format, :filters]

  @doc """
  Start the console backend.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry)
    backend_config = Keyword.get(config, :backends, [])
    console_config = Keyword.get(backend_config, :console, [])
    final_config = Keyword.merge(console_config, opts)

    GenServer.start_link(__MODULE__, final_config, name: __MODULE__)
  end

  @doc """
  Handle a telemetry event.
  """
  @spec handle_event([atom()], map(), map()) :: :ok
  def handle_event(event_name, measurements, metadata) do
    GenServer.cast(__MODULE__, {:handle_event, event_name, measurements, metadata})
  end

  @doc """
  Handle metrics data from the reporter.
  """
  @spec handle_metrics([atom()], map(), [tuple()]) :: :ok
  def handle_metrics(event_name, aggregates, raw_events) do
    GenServer.cast(__MODULE__, {:handle_metrics, event_name, aggregates, raw_events})
  end

  @doc """
  Handle a complete metrics report.
  """
  @spec handle_report(map()) :: :ok
  def handle_report(report) do
    GenServer.cast(__MODULE__, {:handle_report, report})
  end

  @impl true
  def init(opts) do
    colors = Keyword.get(opts, :colors, @default_colors)
    format = Keyword.get(opts, :format, @default_format)
    min_level = Keyword.get(opts, :level, :info)
    filters = Keyword.get(opts, :filters, [])
    show_metrics = Keyword.get(opts, :show_metrics, true)
    show_events = Keyword.get(opts, :show_events, true)
    colored = Keyword.get(opts, :colored, true)

    state = %__MODULE__{
      config: %{
        level: min_level,
        show_metrics: show_metrics,
        show_events: show_events,
        colored: colored
      },
      colors: colors,
      format: format,
      filters: filters
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_event, event_name, measurements, metadata}, state) do
    if state.config.show_events do
      output_event(event_name, measurements, metadata, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_metrics, event_name, aggregates, raw_events}, state) do
    if state.config.show_metrics do
      output_metrics(event_name, aggregates, raw_events, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:handle_report, report}, state) do
    if state.config.show_metrics do
      output_report(report, state)
    end

    {:noreply, state}
  end

  @impl true
  def handle_cast({:update_config, new_opts}, state) do
    updated_config = Map.merge(state.config, Map.new(new_opts))

    new_state = %{
      state
      | config: updated_config,
        colors: Keyword.get(new_opts, :colors, state.colors),
        format: Keyword.get(new_opts, :format, state.format),
        filters: Keyword.get(new_opts, :filters, state.filters)
    }

    {:noreply, new_state}
  end

  defp output_event(event_name, measurements, metadata, state) do
    # Determine log level from metadata or event name
    level = determine_event_level(event_name, measurements, metadata)

    if should_log?(level, state) and should_filter_event?(event_name, metadata, state) do
      # Format the event for console output
      formatted = format_event(event_name, measurements, metadata, level, state)

      # Output with color if enabled
      if state.config.colored do
        color = Map.get(state.colors, level, :normal)
        IO.puts(IO.ANSI.format([color, formatted]))
      else
        IO.puts(formatted)
      end
    end
  end

  defp output_metrics(event_name, aggregates, _raw_events, _state) do
    event_str = Enum.join(event_name, ".")

    # Output summary
    summary = "#{event_str}: #{aggregates.count} events in #{aggregates.duration_ms}ms"
    IO.puts(IO.ANSI.format([:bright, summary]))

    # Output measurement aggregates
    Enum.each(aggregates.aggregates, fn {measurement_name, stats} ->
      stats_str =
        "  #{measurement_name}: avg=#{Float.round(stats.avg, 2)}, min=#{stats.min}, max=#{stats.max}, count=#{stats.count}"

      IO.puts("  #{stats_str}")
    end)

    # Empty line for readability
    IO.puts("")
  end

  defp output_report(report, _state) do
    timestamp = format_timestamp(DateTime.to_iso8601(report.timestamp))

    IO.puts(IO.ANSI.format([:bright, :underline, "METRICS REPORT - #{timestamp}"]))
    IO.puts("")

    # Summary statistics
    IO.puts(IO.ANSI.format([:bright, "Summary:"]))
    IO.puts("  Total events: #{report.total_events}")

    IO.puts(
      "  Unique event types: #{report.unique_event_types || length(report.top_events || [])}"
    )

    IO.puts("  Active reporters: #{report.active_reporters}")
    IO.puts("")

    # Top events
    if report.top_events && length(report.top_events) > 0 do
      IO.puts(IO.ANSI.format([:bright, "Top Events:"]))

      Enum.take(report.top_events, 5)
      |> Enum.each(fn {event_name, count} ->
        event_str = Enum.join(event_name, ".")
        IO.puts("  #{event_str}: #{count} events")
      end)

      IO.puts("")
    end

    # Error rates
    if report.error_rates && length(report.error_rates) > 0 do
      IO.puts(IO.ANSI.format([:bright, "Error Rates:"]))

      Enum.take(report.error_rates, 5)
      |> Enum.each(fn {event_name, %{error_rate: rate}} ->
        if rate > 0 do
          event_str = Enum.join(event_name, ".")
          IO.puts(IO.ANSI.format([:red, "  #{event_str}: #{Float.round(rate, 2)}% error rate"]))
        end
      end)

      IO.puts("")
    end

    # Average durations
    if report.average_durations && length(report.average_durations) > 0 do
      IO.puts(IO.ANSI.format([:bright, "Average Durations:"]))

      Enum.take(report.average_durations, 5)
      |> Enum.each(fn {event_name, durations} ->
        event_str = Enum.join(event_name, ".")

        Enum.each(durations, fn {measurement_name, avg} ->
          IO.puts("  #{event_str}.#{measurement_name}: #{Float.round(avg, 2)}ms")
        end)
      end)

      IO.puts("")
    end

    IO.puts(IO.ANSI.format([:faint, "---"]))
  end

  defp format_event(event_name, measurements, metadata, level, _state) do
    timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
    level_str = String.upcase(Atom.to_string(level))
    event_str = Enum.join(event_name, ".")

    # Build message from metadata
    message =
      case metadata do
        %{message: msg} -> msg
        _ -> "Event: #{event_str}"
      end

    # Format measurements
    measurements_str =
      if map_size(measurements) > 0 do
        measurements
        |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
        |> Enum.join(" ")
      else
        ""
      end

    # Format metadata
    metadata_str =
      if map_size(metadata) > 0 do
        filtered_metadata = Map.delete(metadata, :message)

        if map_size(filtered_metadata) > 0 do
          filtered_metadata
          |> Enum.map(fn {k, v} -> "#{k}=#{format_value(v)}" end)
          |> Enum.join(" ")
        else
          ""
        end
      else
        ""
      end

    # Combine all parts
    parts = [
      "[#{timestamp}]",
      "#{level_str}:",
      message
    ]

    parts =
      if measurements_str != "" do
        parts ++ ["(#{measurements_str})"]
      else
        parts
      end

    parts =
      if metadata_str != "" do
        parts ++ ["[#{metadata_str}]"]
      else
        parts
      end

    Enum.join(parts, " ")
  end

  defp determine_event_level(_event_name, measurements, metadata) do
    cond do
      # Use explicit level from metadata
      Map.has_key?(metadata, :level) ->
        Map.get(metadata, :level)

      # Error status
      metadata[:status] == :error or metadata[:kind] == :exception ->
        :error

      # HTTP error responses
      metadata[:status] && metadata[:status] >= 400 ->
        if metadata[:status] >= 500, do: :error, else: :warn

      # High duration measurements
      has_long_duration?(measurements) ->
        :warn

      # Security events
      metadata[:security] ->
        :warn

      # Default to info
      true ->
        :info
    end
  end

  defp has_long_duration?(measurements) do
    Enum.any?(measurements, fn {key, value} ->
      # > 1 second
      (String.contains?(Atom.to_string(key), "duration") or
         String.contains?(Atom.to_string(key), "time")) and
        is_number(value) and value > 1000
    end)
  end

  defp should_log?(level, state) do
    GSMLG.Telemetry.Logger.compare_levels(level, state.config.level) != :lt
  end

  defp should_filter_event?(event_name, metadata, state) do
    # Check against configured filters
    Enum.all?(state.filters, fn filter ->
      case filter do
        {key, value} when is_atom(key) ->
          Map.get(metadata, key) != value

        {key, predicate} when is_function(predicate, 1) ->
          not predicate.(Map.get(metadata, key))

        predicate when is_function(predicate, 1) ->
          not predicate.(event_name)

        _ ->
          true
      end
    end)
  end

  defp format_value(value) when is_binary(value) do
    if String.length(value) > 100 do
      String.slice(value, 0, 97) <> "..."
    else
      value
    end
  end

  defp format_value(value) when is_atom(value) do
    ":" <> Atom.to_string(value)
  end

  defp format_value(value) when is_number(value) do
    if is_float(value) do
      Float.round(value, 3)
    else
      value
    end
  end

  defp format_value(value) when is_list(value) do
    if length(value) > 10 do
      "List[#{length(value)} items]"
    else
      inspect(value, pretty: false, limit: 50)
    end
  end

  defp format_value(value) when is_map(value) do
    if map_size(value) > 5 do
      "Map[#{map_size(value)} keys]"
    else
      inspect(value, pretty: false, limit: 50)
    end
  end

  defp format_value(value) do
    inspect(value, pretty: false, limit: 50)
  end

  defp format_timestamp(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} ->
        dt |> DateTime.to_time() |> Time.to_string()

      _ ->
        iso_string
    end
  end

  @doc """
  Update console backend configuration at runtime.
  """
  @spec update_config(keyword()) :: :ok
  def update_config(new_opts) do
    GenServer.cast(__MODULE__, {:update_config, new_opts})
  end

  @doc """
  Get current console backend configuration.
  """
  @spec get_config() :: map()
  def get_config do
    GenServer.call(__MODULE__, :get_config)
  end

  @impl true
  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end
end
