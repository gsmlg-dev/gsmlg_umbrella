defmodule GSMLG.Telemetry.Backends.CloudWatch do
  @moduledoc """
  AWS CloudWatch Logs backend for GSMLG telemetry system.

  This backend sends telemetry events to AWS CloudWatch Logs with
  batching, error handling, and automatic retry logic.
  """

  use GenServer
  require Logger

  @default_buffer_size 100
  @default_flush_interval 5_000
  @default_max_retries 3
  @default_retry_delay 1_000
  @default_region "us-east-1"

  defstruct [:config, :buffer, :client, :sequence_token, :last_flush_time]

  @doc """
  Start the CloudWatch backend.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    config = Application.get_all_env(:gsmlg_telemetry)
    backend_config = Keyword.get(config, :backends, [])
    cloudwatch_config = Keyword.get(backend_config, :cloudwatch, [])
    final_config = Keyword.merge(cloudwatch_config, opts)

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
  Force flush the buffer to CloudWatch.
  """
  @spec flush() :: :ok
  def flush do
    GenServer.cast(__MODULE__, :flush)
  end

  @doc """
  Get CloudWatch backend statistics.
  """
  @spec get_stats() :: map()
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  @impl true
  def init(opts) do
    enabled = Keyword.get(opts, :enabled, false)

    unless enabled do
      Logger.info("CloudWatch backend disabled")
    end

    if enabled do
      do_init(opts)
    else
      :ignore
    end
  end

  defp do_init(opts) do
    log_group_name =
      Keyword.get(opts, :log_group_name) ||
        raise ArgumentError, "log_group_name is required for CloudWatch backend"

    log_stream_name =
      Keyword.get(opts, :log_stream_name) ||
        raise ArgumentError, "log_stream_name is required for CloudWatch backend"

    region = Keyword.get(opts, :region, @default_region)
    buffer_size = Keyword.get(opts, :buffer_size, @default_buffer_size)
    flush_interval = Keyword.get(opts, :flush_interval, @default_flush_interval)
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    retry_delay = Keyword.get(opts, :retry_delay, @default_retry_delay)
    min_level = Keyword.get(opts, :level, :info)

    # Initialize CloudWatch client
    client = init_cloudwatch_client(region, opts)

    config = %{
      enabled: true,
      log_group_name: log_group_name,
      log_stream_name: log_stream_name,
      region: region,
      buffer_size: buffer_size,
      flush_interval: flush_interval,
      max_retries: max_retries,
      retry_delay: retry_delay,
      min_level: min_level
    }

    # Initialize buffer
    buffer = []

    # Get sequence token for log stream
    sequence_token = get_sequence_token(client, log_group_name, log_stream_name)

    # Schedule periodic flush
    schedule_flush(flush_interval)

    state = %__MODULE__{
      config: config,
      buffer: buffer,
      client: client,
      sequence_token: sequence_token,
      last_flush_time: DateTime.utc_now()
    }

    Logger.info("CloudWatch backend started for #{log_group_name}/#{log_stream_name}")
    {:ok, state}
  end

  @impl true
  def handle_cast({:handle_event, event_name, measurements, metadata}, state) do
    if not state.config.enabled do
      {:noreply, state}
    end

    level = determine_event_level(event_name, measurements, metadata)

    if should_log?(level, state.config.min_level) do
      log_event = create_cloudwatch_log_event(:event, event_name, measurements, metadata, level)
      new_state = add_to_buffer(log_event, state)

      # Check if we need to flush
      if length(new_state.buffer) >= state.config.buffer_size do
        {:noreply, flush_to_cloudwatch(new_state)}
      else
        {:noreply, new_state}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:handle_metrics, event_name, aggregates, raw_events}, state) do
    if not state.config.enabled do
      {:noreply, state}
    end

    log_event =
      create_cloudwatch_log_event(:metrics, event_name, aggregates, %{events: raw_events})

    new_state = add_to_buffer(log_event, state)

    if length(new_state.buffer) >= state.config.buffer_size do
      {:noreply, flush_to_cloudwatch(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast({:handle_report, report}, state) do
    if not state.config.enabled do
      {:noreply, state}
    end

    log_event = create_cloudwatch_log_event(:report, nil, report, %{})
    new_state = add_to_buffer(log_event, state)

    if length(new_state.buffer) >= state.config.buffer_size do
      {:noreply, flush_to_cloudwatch(new_state)}
    else
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_cast(:flush, state) do
    if state.config.enabled do
      new_state = flush_to_cloudwatch(state)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_config, new_opts}, state) do
    updated_config = Map.merge(state.config, Map.new(new_opts))
    new_state = %{state | config: updated_config}
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:flush_to_cloudwatch, state) do
    if state.config.enabled do
      new_state = flush_to_cloudwatch(state)
      schedule_flush(state.config.flush_interval)
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      enabled: state.config.enabled,
      log_group_name: state.config.log_group_name,
      log_stream_name: state.config.log_stream_name,
      buffer_size: length(state.buffer),
      last_flush_time: state.last_flush_time,
      sequence_token: state.sequence_token != nil
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_call(:test_connectivity, _from, state) do
    if not state.config.enabled do
      {:reply, {:error, :disabled}, state}
    else
      case describe_log_streams(
             state.client,
             state.config.log_group_name,
             state.config.log_stream_name
           ) do
        {:ok, _} -> {:reply, :ok, state}
        error -> {:reply, error, state}
      end
    end
  end

  # Private functions

  defp init_cloudwatch_client(region, opts) do
    # Try to use GSMLG.AWS client if available
    if Code.ensure_loaded?(GSMLG.AWS.Client) do
      try do
        GSMLG.AWS.Client.new(region: region)
      rescue
        _ -> fallback_cloudwatch_client(region, opts)
      end
    else
      fallback_cloudwatch_client(region, opts)
    end
  end

  defp fallback_cloudwatch_client(region, opts) do
    # Fallback to ex_aws configuration
    ex_aws_config =
      [
        region: region,
        access_key_id: Keyword.get(opts, :access_key_id),
        secret_access_key: Keyword.get(opts, :secret_access_key),
        role_arn: Keyword.get(opts, :role_arn)
      ]
      |> Enum.filter(fn {_, v} -> v != nil end)

    ExAws.new(:cloudwatch_logs, ex_aws_config)
  end

  defp get_sequence_token(client, log_group_name, log_stream_name) do
    # Ensure log group exists
    ensure_log_group_exists(client, log_group_name)

    # Ensure log stream exists
    ensure_log_stream_exists(client, log_group_name, log_stream_name)

    # Get sequence token
    case describe_log_streams(client, log_group_name, log_stream_name) do
      {:ok, %{logStreams: [stream | _]}} ->
        Map.get(stream, :uploadSequenceToken)

      _ ->
        Logger.warning("Could not get sequence token for #{log_group_name}/#{log_stream_name}")
        nil
    end
  end

  defp ensure_log_group_exists(client, log_group_name) do
    case create_log_group(client, log_group_name) do
      {:ok, _} ->
        Logger.info("Created CloudWatch log group: #{log_group_name}")
        :ok

      {:error, {:aws_error, "ResourceAlreadyExistsException"}} ->
        # Log group already exists
        :ok

      {:error, reason} ->
        Logger.error("Failed to create log group #{log_group_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp ensure_log_stream_exists(client, log_group_name, log_stream_name) do
    case create_log_stream(client, log_group_name, log_stream_name) do
      {:ok, _} ->
        Logger.info("Created CloudWatch log stream: #{log_stream_name}")
        :ok

      {:error, {:aws_error, "ResourceAlreadyExistsException"}} ->
        # Log stream already exists
        :ok

      {:error, reason} ->
        Logger.error("Failed to create log stream #{log_stream_name}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_cloudwatch_log_event(type, event_name, data, metadata, level \\ :info) do
    %{
      timestamp: System.system_time(:millisecond),
      message:
        Jason.encode!(%{
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
          type: Atom.to_string(type),
          event_name: if(event_name, do: Enum.join(event_name, "."), else: nil),
          level: Atom.to_string(level),
          data: data,
          metadata: metadata,
          node: node()
        })
    }
  end

  defp add_to_buffer(log_event, state) do
    %{state | buffer: [log_event | state.buffer]}
  end

  defp flush_to_cloudwatch(state) do
    if length(state.buffer) > 0 do
      # Reverse buffer to maintain order
      events = Enum.reverse(state.buffer)

      case put_log_events(
             state.client,
             state.config.log_group_name,
             state.config.log_stream_name,
             events,
             state.sequence_token
           ) do
        {:ok, %{nextSequenceToken: next_token}} ->
          Logger.debug("Sent #{length(events)} log events to CloudWatch")
          %{state | buffer: [], sequence_token: next_token, last_flush_time: DateTime.utc_now()}

        {:ok, result} ->
          Logger.debug("Sent #{length(events)} log events to CloudWatch: #{inspect(result)}")
          %{state | buffer: [], last_flush_time: DateTime.utc_now()}

        {:error, reason} ->
          Logger.error("Failed to send log events to CloudWatch: #{inspect(reason)}")
          # Keep events in buffer for retry
          %{state | last_flush_time: DateTime.utc_now()}
      end
    else
      state
    end
  end

  defp determine_event_level(_event_name, measurements, metadata) do
    cond do
      Map.has_key?(metadata, :level) ->
        Map.get(metadata, :level)

      metadata[:status] == :error ->
        :error

      metadata[:kind] == :exception ->
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
    Process.send_after(self(), :flush_to_cloudwatch, interval)
  end

  # CloudWatch API wrappers using GSMLG.AWS or ex_aws

  defp create_log_group(client, log_group_name) do
    if Code.ensure_loaded?(GSMLG.AWS.CloudWatchLogs) do
      GSMLG.AWS.CloudWatchLogs.create_log_group(client, log_group_name)
    else
      ExAws.CloudWatchLogs.create_log_group(log_group_name)
      |> ExAws.request(client)
    end
  end

  defp create_log_stream(client, log_group_name, log_stream_name) do
    if Code.ensure_loaded?(GSMLG.AWS.CloudWatchLogs) do
      GSMLG.AWS.CloudWatchLogs.create_log_stream(client, log_group_name, log_stream_name)
    else
      ExAws.CloudWatchLogs.create_log_stream(log_group_name, log_stream_name)
      |> ExAws.request(client)
    end
  end

  defp describe_log_streams(client, log_group_name, log_stream_name) do
    if Code.ensure_loaded?(GSMLG.AWS.CloudWatchLogs) do
      GSMLG.AWS.CloudWatchLogs.describe_log_streams(client, log_group_name, log_stream_name)
    else
      ExAws.CloudWatchLogs.describe_log_streams(log_group_name, log_stream_name: log_stream_name)
      |> ExAws.request(client)
    end
  end

  defp put_log_events(client, log_group_name, log_stream_name, events, sequence_token) do
    params = %{
      logGroupName: log_group_name,
      logStreamName: log_stream_name,
      logEvents: events
    }

    params =
      if sequence_token do
        Map.put(params, :sequenceToken, sequence_token)
      else
        params
      end

    if Code.ensure_loaded?(GSMLG.AWS.CloudWatchLogs) do
      GSMLG.AWS.CloudWatchLogs.put_log_events(client, params)
    else
      ExAws.CloudWatchLogs.put_log_events(params)
      |> ExAws.request(client)
    end
  end

  @doc """
  Update CloudWatch backend configuration at runtime.
  """
  @spec update_config(keyword()) :: :ok
  def update_config(new_opts) do
    GenServer.cast(__MODULE__, {:update_config, new_opts})
  end

  @doc """
  Test CloudWatch connectivity.
  """
  @spec test_connectivity() :: :ok | {:error, term()}
  def test_connectivity do
    GenServer.call(__MODULE__, :test_connectivity)
  end
end
