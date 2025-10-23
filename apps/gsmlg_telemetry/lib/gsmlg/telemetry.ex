defmodule GSMLG.Telemetry do
  @moduledoc """
  Centralized telemetry and logging for GSMLG applications.

  This module provides a unified interface for:
  - Structured logging with metadata
  - Custom event emission
  - Span tracking for operations
  - Metrics collection

  ## Examples

      # Logging with metadata
      GSMLG.Telemetry.log(:info, "User logged in", metadata: %{user_id: 123, ip: "1.2.3.4"})

      # Emit custom events
      GSMLG.Telemetry.emit([:gsmlg, :web, :request], %{duration: 150}, %{path: "/api"})

      # Span tracking
      GSMLG.Telemetry.span([:gsmlg, :repo, :query], %{}, fn ->
        result = Database.query("SELECT * FROM users")
        {:ok, result}
      end)
  """

  alias GSMLG.Telemetry.Logger
  alias GSMLG.Telemetry.Handler

  @doc """
  Log a message with the specified level and metadata.

  ## Parameters

  - `level` - The log level (:debug, :info, :warn, :error)
  - `message` - The log message (string or any term that implements `String.Chars`)
  - `opts` - Keyword list of options:
    - `:metadata` - Map of additional metadata to include
    - `:telemetry_event` - List representing the telemetry event name (optional)
    - `:measurements` - Map of measurements to include (optional)

  ## Examples

      GSMLG.Telemetry.log(:info, "Processing request", metadata: %{request_id: "123"})
      GSMLG.Telemetry.log(:error, "Database connection failed", metadata: %{error: "timeout"})
  """
  @spec log(atom(), any(), keyword()) :: :ok
  def log(level, message, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    telemetry_event = Keyword.get(opts, :telemetry_event, [:gsmlg, :log])
    measurements = Keyword.get(opts, :measurements, %{})

    # Emit telemetry event
    :telemetry.execute(
      telemetry_event,
      Map.put(measurements, :level, level),
      Map.put(metadata, :message, message)
    )

    # Log using our logger wrapper
    Logger.log(level, message, metadata)
  end

  @doc """
  Emit a custom telemetry event.

  ## Parameters

  - `event_name` - List representing the event name (e.g., [:gsmlg, :web, :request])
  - `measurements` - Map of measurements (numeric values, durations, counts, etc.)
  - `metadata` - Map of metadata context

  ## Examples

      GSMLG.Telemetry.emit([:gsmlg, :web, :request], %{duration: 150}, %{path: "/api"})
      GSMLG.Telemetry.emit([:gsmlg, :repo, :query], %{rows: 10}, %{table: "users"})
  """
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event_name, measurements \\ %{}, metadata \\ %{}) do
    :telemetry.execute(event_name, measurements, metadata)
  end

  @doc """
  Execute a function within a telemetry span, measuring its duration.

  ## Parameters

  - `event_name` - List representing the span event name
  - `metadata` - Map of metadata to include with the span
  - `function` - Function to execute within the span

  ## Returns

  Returns the result of the function.

  ## Examples

      result = GSMLG.Telemetry.span([:gsmlg, :repo, :query], %{query: "SELECT *"}, fn ->
        Database.query("SELECT * FROM users")
      end)
  """
  @spec span([atom()], map(), function()) :: any()
  def span(event_name, metadata, function) when is_function(function, 0) do
    start_time = System.monotonic_time()

    try do
      result = function.()

      # Emit success event
      measurements = %{
        duration: System.monotonic_time() - start_time,
        monotonic_time: start_time
      }

      :telemetry.execute(event_name, measurements, Map.put(metadata, :status, :ok))

      result
    rescue
      exception ->
        # Emit exception event
        measurements = %{
          duration: System.monotonic_time() - start_time,
          monotonic_time: start_time
        }

        error_metadata =
          metadata
          |> Map.put(:status, :error)
          |> Map.put(:error, Exception.message(exception))
          |> Map.put(:kind, :exception)

        :telemetry.execute(event_name, measurements, error_metadata)

        reraise exception, __STACKTRACE__
    catch
      kind, value ->
        # Emit catch event
        measurements = %{
          duration: System.monotonic_time() - start_time,
          monotonic_time: start_time
        }

        error_metadata =
          metadata
          |> Map.put(:status, :error)
          |> Map.put(:error, inspect(value))
          |> Map.put(:kind, kind)

        :telemetry.execute(event_name, measurements, error_metadata)

        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  @doc """
  Execute a function within a telemetry span with extra metadata.

  Similar to `span/3` but allows the function to return additional metadata
  along with the result.

  ## Parameters

  - `event_name` - List representing the span event name
  - `base_metadata` - Map of base metadata to include
  - `function` - Function that returns `{result, metadata}` or `{result, metadata, measurements}`

  ## Examples

      {result, extra_meta} = GSMLG.Telemetry.span_with_metadata([:gsmlg, :cache, :get], %{key: "user:123"}, fn ->
        case Cache.get("user:123") do
          nil -> {:miss, %{cache_hit: false}, %{count: 0}}
          user -> {:hit, %{cache_hit: true, user_id: user.id}, %{count: 1}}
        end
      end)
  """
  @spec span_with_metadata([atom()], map(), function()) :: {any(), map()}
  def span_with_metadata(event_name, base_metadata, function) when is_function(function, 0) do
    start_time = System.monotonic_time()

    try do
      case function.() do
        {result, extra_metadata} ->
          measurements = %{
            duration: System.monotonic_time() - start_time,
            monotonic_time: start_time
          }

          metadata =
            base_metadata
            |> Map.merge(extra_metadata)
            |> Map.put(:status, :ok)

          :telemetry.execute(event_name, measurements, metadata)

          {result, extra_metadata}

        {result, extra_metadata, extra_measurements} ->
          measurements =
            extra_measurements
            |> Map.put(:duration, System.monotonic_time() - start_time)
            |> Map.put(:monotonic_time, start_time)

          metadata =
            base_metadata
            |> Map.merge(extra_metadata)
            |> Map.put(:status, :ok)

          :telemetry.execute(event_name, measurements, metadata)

          {result, extra_metadata}

        result ->
          measurements = %{
            duration: System.monotonic_time() - start_time,
            monotonic_time: start_time
          }

          :telemetry.execute(event_name, measurements, Map.put(base_metadata, :status, :ok))

          {result, %{}}
      end
    rescue
      exception ->
        measurements = %{
          duration: System.monotonic_time() - start_time,
          monotonic_time: start_time
        }

        error_metadata =
          base_metadata
          |> Map.put(:status, :error)
          |> Map.put(:error, Exception.message(exception))
          |> Map.put(:kind, :exception)

        :telemetry.execute(event_name, measurements, error_metadata)

        reraise exception, __STACKTRACE__
    catch
      kind, value ->
        measurements = %{
          duration: System.monotonic_time() - start_time,
          monotonic_time: start_time
        }

        error_metadata =
          base_metadata
          |> Map.put(:status, :error)
          |> Map.put(:error, inspect(value))
          |> Map.put(:kind, kind)

        :telemetry.execute(event_name, measurements, error_metadata)

        :erlang.raise(kind, value, __STACKTRACE__)
    end
  end

  @doc """
  Get the current configuration.
  """
  @spec config() :: keyword()
  def config, do: Application.get_all_env(:gsmlg_telemetry)

  @doc """
  Check if a log level is enabled.
  """
  @spec enabled?(atom()) :: boolean()
  def enabled?(level) do
    min_level = config() |> Keyword.get(:level, :info)
    Logger.compare_levels(level, min_level) != :lt
  end

  @doc """
  Attach a telemetry handler.

  ## Parameters

  - `handler_id` - Unique identifier for the handler
  - `event_name` - Event name or list of event names to handle
  - `handler_module` - Module implementing the handler behavior
  - `handler_config` - Configuration passed to the handler

  ## Examples

      GSMLG.Telemetry.attach_handler(:my_handler, [:gsmlg, :web], MyHandler, [])
  """
  @spec attach_handler(atom(), [atom()] | atom(), atom(), any()) ::
          :ok | {:error, :already_exists}
  def attach_handler(handler_id, event_name, handler_module, handler_config \\ %{}) do
    Handler.attach(handler_id, event_name, handler_module, handler_config)
  end

  @doc """
  Detach a telemetry handler.
  """
  @spec detach_handler(atom()) :: :ok | {:error, :not_found}
  def detach_handler(handler_id) do
    Handler.detach(handler_id)
  end

  # Convenience macros for common log levels

  @doc """
  Log a debug message.
  """
  @spec debug(any(), keyword()) :: :ok
  def debug(message, opts \\ []), do: log(:debug, message, opts)

  @doc """
  Log an info message.
  """
  @spec info(any(), keyword()) :: :ok
  def info(message, opts \\ []), do: log(:info, message, opts)

  @doc """
  Log a warning message.
  """
  @spec warn(any(), keyword()) :: :ok
  def warn(message, opts \\ []), do: log(:warn, message, opts)

  @doc """
  Log an error message.
  """
  @spec error(any(), keyword()) :: :ok
  def error(message, opts \\ []), do: log(:error, message, opts)

  @doc """
  Log an exception with stacktrace.

  ## Parameters

  - `exception` - The exception struct
  - `stacktrace` - The stacktrace from __STACKTRACE__
  - `opts` - Keyword list of options (metadata will be extracted if present)

  ## Examples

      try do
        risky_operation()
      rescue
        e ->
          GSMLG.Telemetry.exception(e, __STACKTRACE__, metadata: %{operation: "risky"})
      end
  """
  @spec exception(Exception.t(), Exception.stacktrace(), keyword()) :: :ok
  def exception(exception, stacktrace, opts \\ []) do
    metadata = Keyword.get(opts, :metadata, %{})
    Logger.exception_with_stacktrace(exception, stacktrace, metadata)
  end
end
