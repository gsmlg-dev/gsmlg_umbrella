defmodule GSMLG.Telemetry.Backends.File do
  @moduledoc """
  File backend for GSMLG telemetry system.

  This backend writes telemetry events to log files with rotation,
  compression, and structured formatting capabilities.
  """

  use GenServer
  require Logger

  @default_file_path "logs/gsmlg.log"
  # 50MB
  @default_max_file_size 50 * 1024 * 1024
  @default_max_files 5
  @default_format :json

  defstruct [:file_path, :device, :config, :rotation_state, :buffer]

  @doc """
  Start the file backend.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry)
    backend_config = Keyword.get(config, :backends, [])
    file_config = Keyword.get(backend_config, :file, [])
    final_config = Keyword.merge(file_config, opts)

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

  @doc """
  Force log rotation.
  """
  @spec rotate_log() :: :ok
  def rotate_log do
    GenServer.cast(__MODULE__, :rotate_log)
  end

  @doc """
  Flush the buffer to disk.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  @impl true
  def init(opts) do
    file_path = Keyword.get(opts, :path, @default_file_path)
    max_file_size = Keyword.get(opts, :max_file_size, @default_max_file_size)
    max_files = Keyword.get(opts, :max_files, @default_max_files)
    format = Keyword.get(opts, :format, @default_format)
    buffer_size = Keyword.get(opts, :buffer_size, 100)
    flush_interval = Keyword.get(opts, :flush_interval, 5_000)
    min_level = Keyword.get(opts, :level, :info)
    compress = Keyword.get(opts, :compress, true)
    sync_mode = Keyword.get(opts, :sync_mode, :async)

    # Ensure log directory exists
    log_dir = Path.dirname(file_path)
    File.mkdir_p!(log_dir)

    # Open or create log file
    device = open_log_file(file_path)

    config = %{
      max_file_size: max_file_size,
      max_files: max_files,
      format: format,
      buffer_size: buffer_size,
      flush_interval: flush_interval,
      min_level: min_level,
      compress: compress,
      sync_mode: sync_mode
    }

    # Initialize buffer
    buffer = :queue.new()

    # Initialize rotation state
    rotation_state = %{
      current_size: get_file_size(file_path),
      last_rotation: DateTime.utc_now()
    }

    # Schedule periodic flush
    schedule_flush(flush_interval)

    state = %__MODULE__{
      file_path: file_path,
      device: device,
      config: config,
      rotation_state: rotation_state,
      buffer: buffer
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_event, event_name, measurements, metadata}, state) do
    # Determine if we should log this event
    level = determine_event_level(event_name, measurements, metadata)

    if should_log?(level, state.config.min_level) do
      log_entry = create_log_entry(:event, event_name, measurements, metadata, level)
      new_state = buffer_log_entry(log_entry, state)

      # Check if we need to flush buffer
      if :queue.len(new_state.buffer) >= new_state.config.buffer_size do
        {:noreply, flush_buffer(new_state)}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:handle_metrics, event_name, aggregates, raw_events}, state) do
    log_entry = create_log_entry(:metrics, event_name, aggregates, %{events: raw_events})
    new_state = buffer_log_entry(log_entry, state)

    if :queue.len(new_state.buffer) >= new_state.config.buffer_size do
      {:noreply, flush_buffer(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:handle_report, report}, state) do
    log_entry = create_log_entry(:report, nil, report, %{})
    new_state = buffer_log_entry(log_entry, state)

    if :queue.len(new_state.buffer) >= new_state.config.buffer_size do
      {:noreply, flush_buffer(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:rotate_log, state) do
    new_state = rotate_log_file(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:flush, state) do
    new_state = flush_buffer(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:flush_buffer, state) do
    new_state = flush_buffer(state)
    schedule_flush(state.config.flush_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:EXIT, device, reason}, state) do
    if device == state.device do
      Logger.error("File device crashed: #{inspect(reason)}, attempting to reopen...")

      case reopen_log_file(state) do
        {:ok, new_state} ->
          {:noreply, new_state}

        {:error, reason} ->
          Logger.error("Failed to reopen log file: #{inspect(reason)}")
          {:noreply, %{state | device: nil}}
      end
    else
      {:noreply, state}
    end
  end

  defp open_log_file(file_path) do
    case File.open(file_path, [:append, :utf8]) do
      {:ok, device} ->
        device

      {:error, reason} ->
        Logger.error("Failed to open log file #{file_path}: #{inspect(reason)}")
        raise "Failed to open log file: #{inspect(reason)}"
    end
  end

  defp reopen_log_file(state) do
    case File.open(state.file_path, [:append, :utf8]) do
      {:ok, device} ->
        new_state = %{state | device: device}
        {:ok, new_state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_file_size(file_path) do
    case File.stat(file_path) do
      {:ok, stat} -> stat.size
      {:error, _} -> 0
    end
  end

  defp buffer_log_entry(log_entry, state) do
    new_buffer = :queue.in(log_entry, state.buffer)
    %{state | buffer: new_buffer}
  end

  defp flush_buffer(state) do
    if state.device do
      case :queue.out(state.buffer) do
        {{:value, log_entry}, remaining_buffer} ->
          write_log_entry(log_entry, state)
          flush_buffer(%{state | buffer: remaining_buffer})

        {:empty, _} ->
          # Buffer is empty, sync if needed
          if state.config.sync_mode == :sync do
            :file.sync(state.device)
          end

          %{state | buffer: :queue.new()}
      end
    else
      state
    end
  end

  defp write_log_entry(log_entry, state) do
    formatted_line = format_log_entry(log_entry, state.config.format)
    IO.write(state.device, formatted_line <> "\n")

    # Update current file size
    new_size = state.rotation_state.current_size + byte_size(formatted_line) + 1
    new_rotation_state = %{state.rotation_state | current_size: new_size}

    # Check if we need to rotate
    if new_size >= state.config.max_file_size do
      %{state | rotation_state: new_rotation_state}
      |> rotate_log_file()
    else
      %{state | rotation_state: new_rotation_state}
    end
  end

  defp rotate_log_file(state) do
    if state.device do
      File.close(state.device)
    end

    # Rotate existing files
    rotate_existing_files(state.file_path, state.config.max_files, state.config.compress)

    # Open new file
    new_device = open_log_file(state.file_path)

    new_rotation_state = %{
      current_size: 0,
      last_rotation: DateTime.utc_now()
    }

    %{state | device: new_device, rotation_state: new_rotation_state}
  end

  defp rotate_existing_files(file_path, max_files, compress) do
    # Remove oldest file if it exists
    oldest_file = "#{file_path}.#{max_files}"
    File.rm(oldest_file)

    # Rotate existing files in reverse order
    (max_files - 1)..1
    |> Enum.each(fn i ->
      current_file = if i == 1, do: file_path, else: "#{file_path}.#{i - 1}"
      next_file = "#{file_path}.#{i}"

      if File.exists?(current_file) do
        File.rename(current_file, next_file)

        # Compress if enabled and not the newest file
        if compress and i > 1 do
          compress_file(next_file)
        end
      end
    end)

    # Compress the rotated file if enabled
    if compress and File.exists?("#{file_path}.1") do
      compress_file("#{file_path}.1")
    end
  end

  defp compress_file(file_path) do
    case File.read(file_path) do
      {:ok, content} ->
        compressed = :zlib.gzip(content)
        compressed_path = file_path <> ".gz"
        File.write!(compressed_path, compressed)
        File.rm(file_path)

      {:error, reason} ->
        Logger.warning("Failed to compress file #{file_path}: #{inspect(reason)}")
    end
  end

  defp create_log_entry(type, event_name, data, metadata, level \\ :info) do
    %{
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: type,
      event_name: event_name,
      data: data,
      metadata: metadata,
      level: level,
      node: node()
    }
  end

  defp format_log_entry(log_entry, :json) do
    Jason.encode!(log_entry)
  end

  defp format_log_entry(log_entry, :ltsv) do
    # LTSV (Labeled Tab Separated Values) format
    fields = [
      {"time", log_entry.timestamp},
      {"type", Atom.to_string(log_entry.type)},
      {"level", Atom.to_string(log_entry.level)},
      {"node", Atom.to_string(log_entry.node)}
    ]

    fields =
      if log_entry.event_name do
        [{"event", Enum.join(log_entry.event_name, ".")} | fields]
      else
        fields
      end

    # Add data as fields
    data_fields =
      Enum.map(log_entry.data, fn {k, v} ->
        {Atom.to_string(k), format_value_for_ltsv(v)}
      end)

    # Add metadata as fields
    metadata_fields =
      Enum.map(log_entry.metadata, fn {k, v} ->
        {Atom.to_string(k), format_value_for_ltsv(v)}
      end)

    (fields ++ data_fields ++ metadata_fields)
    |> Enum.map(fn {k, v} -> "#{k}:#{v}" end)
    |> Enum.join("\t")
  end

  defp format_log_entry(log_entry, :text) do
    timestamp = log_entry.timestamp
    _type = Atom.to_string(log_entry.type)
    level = String.upcase(Atom.to_string(log_entry.type))
    event_str = if log_entry.event_name, do: Enum.join(log_entry.event_name, "."), else: ""

    case log_entry.type do
      :event ->
        message = Map.get(log_entry.metadata, :message, event_str)
        measurements_str = format_measurements_text(log_entry.data)
        metadata_str = format_metadata_text(log_entry.metadata)

        "#{timestamp} [#{level}] #{message}#{measurements_str}#{metadata_str}"

      :metrics ->
        event_str = Enum.join(log_entry.event_name, ".")
        count = Map.get(log_entry.data, :count, 0)
        duration = Map.get(log_entry.data, :duration_ms, 0)

        "#{timestamp} [METRICS] #{event_str}: #{count} events in #{duration}ms"

      :report ->
        total_events = Map.get(log_entry.data, :total_events, 0)
        "#{timestamp} [REPORT] Total events: #{total_events}"
    end
  end

  defp format_value_for_ltsv(value) when is_binary(value) do
    # Escape tabs and newlines for LTSV
    value
    |> String.replace("\t", "\\t")
    |> String.replace("\n", "\\n")
  end

  defp format_value_for_ltsv(value), do: inspect(value)

  defp format_measurements_text(measurements) when map_size(measurements) > 0 do
    " (" <> (measurements |> Enum.map(fn {k, v} -> "#{k}=#{v}" end) |> Enum.join(", ")) <> ")"
  end

  defp format_measurements_text(_), do: ""

  defp format_metadata_text(metadata) when map_size(metadata) > 0 do
    filtered_metadata = Map.delete(metadata, :message)

    if map_size(filtered_metadata) > 0 do
      " [" <>
        (filtered_metadata |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end) |> Enum.join(", ")) <>
        "]"
    else
      ""
    end
  end

  defp format_metadata_text(_), do: ""

  defp determine_event_level(_event_name, measurements, metadata) do
    cond do
      Map.has_key?(metadata, :level) ->
        Map.get(metadata, :level)

      metadata[:status] == :error ->
        :error

      metadata[:status] == :error or metadata[:kind] == :exception ->
        :error

      metadata[:status] && metadata[:status] >= 400 ->
        if metadata[:status] >= 500, do: :error, else: :warn

      has_long_duration?(measurements) ->
        :warn

      metadata[:security] ->
        :warn

      true ->
        :info
    end
  end

  defp has_long_duration?(measurements) do
    Enum.any?(measurements, fn {key, value} ->
      (String.contains?(Atom.to_string(key), "duration") or
         String.contains?(Atom.to_string(key), "time")) and
        is_number(value) and value > 1000
    end)
  end

  defp should_log?(level, min_level) do
    GSMLG.Telemetry.Logger.compare_levels(level, min_level) != :lt
  end

  defp schedule_flush(interval) do
    Process.send_after(self(), :flush_buffer, interval)
  end

  @doc """
  Get file backend statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      file_path: state.file_path,
      current_size: state.rotation_state.current_size,
      max_file_size: state.config.max_file_size,
      buffer_size: :queue.len(state.buffer),
      last_rotation: state.rotation_state.last_rotation,
      device_open: state.device != nil
    }

    {:reply, stats, state}
  end
end
