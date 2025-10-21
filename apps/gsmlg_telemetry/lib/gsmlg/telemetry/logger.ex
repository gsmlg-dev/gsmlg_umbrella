defmodule GSMLG.Telemetry.Logger do
  @moduledoc """
  Logger wrapper for GSMLG telemetry system.

  This module provides structured logging capabilities that integrate with
  the broader telemetry system while maintaining compatibility with the
  existing GSMLG.Logger formatters.
  """

  require Logger

  @levels [:debug, :info, :warn, :error]

  @doc """
  Log a message with the specified level and metadata.

  This function provides a structured logging interface that formats
  messages consistently and includes rich metadata for telemetry analysis.
  """
  @spec log(atom(), any(), map()) :: :ok
  def log(level, message, metadata \\ %{}) when level in @levels do
    if enabled?(level) do
      # Ensure message is a string for consistent formatting
      message_str = case message do
        msg when is_binary(msg) -> msg
        msg -> inspect(msg)
      end

      # Build structured log data
      log_data = %{
        level: level,
        message: message_str,
        timestamp: System.system_time(:millisecond),
        node: node(),
        application: get_application(),
        metadata: enrich_metadata(metadata)
      }

      # Format and log using existing Logger with custom formatter
      formatted_message = format_log_message(log_data)

      Logger.log(level, formatted_message, metadata)
    else
      :ok
    end
  end

  @doc """
  Check if a log level is enabled based on configuration.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(level) when level in @levels do
    min_level = get_min_level()
    compare_levels(level, min_level) != :lt
  end

  @doc """
  Compare two log levels.
  """
  @spec compare_levels(atom(), atom()) :: :lt | :eq | :gt
  def compare_levels(level1, level2) when level1 in @levels and level2 in @levels do
    level_index(@levels, level1) - level_index(@levels, level2)
  end

  @doc """
  Get the current minimum log level from configuration.
  """
  @spec get_min_level() :: atom()
  def get_min_level do
    config = Application.get_all_env(:gsmlg_telemetry)
    Keyword.get(config, :level, :info)
  end

  @doc """
  Log a debug message.
  """
  @spec debug(any(), map()) :: :ok
  def debug(message, metadata \\ %{}), do: log(:debug, message, metadata)

  @doc """
  Log an info message.
  """
  @spec info(any(), map()) :: :ok
  def info(message, metadata \\ %{}), do: log(:info, message, metadata)

  @doc """
  Log a warning message.
  """
  @spec warn(any(), map()) :: :ok
  def warn(message, metadata \\ %{}), do: log(:warn, message, metadata)

  @doc """
  Log an error message.
  """
  @spec error(any(), map()) :: :ok
  def error(message, metadata \\ %{}), do: log(:error, message, metadata)

  @doc """
  Log an exception with stacktrace.
  """
  @spec exception(Exception.t(), Exception.stacktrace(), map()) :: :ok
  def exception(exception, stacktrace \\ __STACKTRACE__, metadata \\ %{}) do
    error_metadata = metadata
    |> Map.put(:exception, Exception.format(:error, exception, stacktrace))
    |> Map.put(:exception_kind, :error)
    |> Map.put(:exception_message, Exception.message(exception))

    log(:error, "Exception: #{Exception.message(exception)}", error_metadata)
  end

  @doc """
  Log a warning about an exception (non-fatal).
  """
  @spec warn_exception(Exception.t(), Exception.stacktrace(), map()) :: :ok
  def warn_exception(exception, stacktrace \\ __STACKTRACE__, metadata \\ %{}) do
    warn_metadata = metadata
    |> Map.put(:exception, Exception.format(:error, exception, stacktrace))
    |> Map.put(:exception_kind, :warning)
    |> Map.put(:exception_message, Exception.message(exception))

    log(:warn, "Warning: #{Exception.message(exception)}", warn_metadata)
  end

  @doc """
  Log performance measurements.
  """
  @spec performance(String.t(), number(), map()) :: :ok
  def performance(operation, duration_ms, metadata \\ %{}) do
    perf_metadata = metadata
    |> Map.put(:operation, operation)
    |> Map.put(:duration_ms, duration_ms)
    |> Map.put(:performance, true)

    log(:info, "Performance: #{operation} took #{duration_ms}ms", perf_metadata)
  end

  @doc """
  Log HTTP request information.
  """
  @spec request(String.t(), atom(), number(), map()) :: :ok
  def request(method, status, duration_ms, metadata \\ %{}) do
    request_metadata = metadata
    |> Map.put(:method, method)
    |> Map.put(:status, status)
    |> Map.put(:duration_ms, duration_ms)
    |> Map.put(:request, true)

    level = if status >= 400, do: :warn, else: :info
    log(level, "#{String.upcase(Atom.to_string(method))} #{status} (#{duration_ms}ms)", request_metadata)
  end

  @doc """
  Log database query information.
  """
  @spec database_query(String.t(), number(), non_neg_integer(), map()) :: :ok
  def database_query(query, duration_ms, result_count \\ nil, metadata \\ %{}) do
    query_metadata = metadata
    |> Map.put(:query, query)
    |> Map.put(:duration_ms, duration_ms)
    |> Map.put(:result_count, result_count)
    |> Map.put(:database, true)

    message = if result_count do
      "DB query (#{result_count} rows) in #{duration_ms}ms: #{truncate_query(query)}"
    else
      "DB query in #{duration_ms}ms: #{truncate_query(query)}"
    end

    level = if duration_ms > 1000, do: :warn, else: :debug
    log(level, message, query_metadata)
  end

  @doc """
  Log user actions for audit purposes.
  """
  @spec audit(String.t(), map()) :: :ok
  def audit(action, metadata \\ %{}) do
    audit_metadata = metadata
    |> Map.put(:action, action)
    |> Map.put(:audit, true)
    |> Map.put(:timestamp, DateTime.utc_now())

    log(:info, "Audit: #{action}", audit_metadata)
  end

  @doc """
  Log security events.
  """
  @spec security(String.t(), map()) :: :ok
  def security(event, metadata \\ %{}) do
    security_metadata = metadata
    |> Map.put(:security_event, event)
    |> Map.put(:security, true)
    |> Map.put(:timestamp, DateTime.utc_now())

    log(:warn, "Security: #{event}", security_metadata)
  end

  # Private functions

  defp format_log_message(log_data) do
    # Use GSMLG.Logger if available, otherwise fall back to basic formatting
    if Code.ensure_loaded?(GSMLG.Logger) do
      try do
        GSMLG.Logger.format(log_data)
      rescue
        _ -> default_format(log_data)
      catch
        _ -> default_format(log_data)
      end
    else
      default_format(log_data)
    end
  end

  defp default_format(log_data) do
    timestamp = format_timestamp(log_data.timestamp)
    level = String.upcase(Atom.to_string(log_data.level))
    message = log_data.message

    base = "[#{timestamp}] #{level} #{message}"

    if map_size(log_data.metadata) > 0 do
      metadata_str = log_data.metadata
      |> Enum.map(fn {k, v} -> "#{k}=#{inspect(v)}" end)
      |> Enum.join(" ")

      "#{base} #{metadata_str}"
    else
      base
    end
  end

  defp format_timestamp(timestamp) do
    timestamp
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp get_application do
    case :application.get_application() do
      {:ok, app} -> app
      :undefined -> :unknown
    end
  end

  defp enrich_metadata(metadata) do
    metadata
    |> Map.put_new(:pid, self())
    |> Map.put_new(:process_info, get_process_info())
  end

  defp get_process_info do
    case Process.info(self(), :registered_name) do
      {:registered_name, name} when name != [] -> name
      _ -> nil
    end
  end

  defp truncate_query(query, max_length \\ 100) do
    if String.length(query) > max_length do
      String.slice(query, 0, max_length) <> "..."
    else
      query
    end
  end

  defp level_index(levels, level) do
    case Enum.find_index(levels, &(&1 == level)) do
      nil -> raise "Invalid log level: #{level}"
      index -> index
    end
  end

  @doc """
  Create a structured logger for a specific context.

  ## Examples

      logger = GSMLG.Telemetry.Logger.context(%{module: MyModule, request_id: "123"})
      logger.info("Processing started")
      logger.error("Processing failed", %{error: "timeout"})
  """
  @spec context(map()) :: module()
  def context(context_metadata) do
    %ContextLogger{metadata: context_metadata}
  end

  defmodule ContextLogger do
    @moduledoc """
    A logger with pre-bound context metadata.
    """

    defstruct [:metadata]

    defimpl String.Chars, for: __MODULE__ do
      def to_string(_), do: "#ContextLogger<>"
    end

    def debug(%__MODULE__{metadata: metadata}, message, extra_metadata \\ %{}) do
      GSMLG.Telemetry.Logger.debug(message, Map.merge(metadata, extra_metadata))
    end

    def info(%__MODULE__{metadata: metadata}, message, extra_metadata \\ %{}) do
      GSMLG.Telemetry.Logger.info(message, Map.merge(metadata, extra_metadata))
    end

    def warn(%__MODULE__{metadata: metadata}, message, extra_metadata \\ %{}) do
      GSMLG.Telemetry.Logger.warn(message, Map.merge(metadata, extra_metadata))
    end

    def error(%__MODULE__{metadata: metadata}, message, extra_metadata \\ %{}) do
      GSMLG.Telemetry.Logger.error(message, Map.merge(metadata, extra_metadata))
    end

    def log(%__MODULE__{metadata: metadata}, level, message, extra_metadata \\ %{}) do
      GSMLG.Telemetry.Logger.log(level, message, Map.merge(metadata, extra_metadata))
    end
  end
end