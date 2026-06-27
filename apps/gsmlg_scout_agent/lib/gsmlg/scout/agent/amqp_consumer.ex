defmodule GSMLG.Scout.Agent.AMQPConsumer do
  @moduledoc """
  RabbitMQ consumer for Scout Agent mode.
  """

  use GenServer
  require Logger

  alias GSMLG.Scout.Agent
  alias GSMLG.Scout.Fetch.{Job, Result}
  alias GSMLG.Scout.Settings

  @default_retry_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    {:ok,
     %{
       connection: nil,
       channel: nil,
       connection_ref: nil,
       channel_ref: nil,
       last_error: nil
     }, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{channel: nil} = state), do: connect(state)
  def handle_continue(:connect, state), do: {:noreply, state}

  @impl true
  def handle_info(:connect, %{channel: nil} = state), do: connect(state)

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    cond do
      ref == state.connection_ref ->
        handle_resource_down(state, reason)

      ref == state.channel_ref ->
        handle_resource_down(state, reason)

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:basic_deliver, payload, meta}, state) do
    delivery_tag = meta.delivery_tag
    channel = state.channel

    case dispatch_delivery(payload, delivery_tag, channel) do
      :ok ->
        {:noreply, state}

      {:error, reason} ->
        Logger.error("[Agent] Failed to dispatch delivery: #{inspect(reason)}")
        safe_nack(channel, delivery_tag)
        {:noreply, state}
    end
  end

  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}

  def handle_info({:basic_cancel, _meta}, state) do
    close_resources(state)

    {:noreply,
     schedule_retry(%{state | connection: nil, channel: nil, last_error: :basic_cancel})}
  end

  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    close_resources(state)
    :ok
  end

  defp connect(state) do
    case rabbitmq().open_channel() do
      {:ok, connection, channel} ->
        consume_open_channel(state, connection, channel)

      {:error, reason} ->
        {:noreply, state |> Map.put(:last_error, reason) |> schedule_retry()}

      reason ->
        {:noreply, state |> Map.put(:last_error, reason) |> schedule_retry()}
    end
  rescue
    exception ->
      {:noreply, state |> Map.put(:last_error, exception) |> schedule_retry()}
  catch
    kind, reason ->
      {:noreply, state |> Map.put(:last_error, {kind, reason}) |> schedule_retry()}
  end

  defp consume_open_channel(state, connection, channel) do
    settings = Settings.get()
    rabbitmq_settings = settings["rabbitmq"]
    agent = settings["agent"]
    queues = jobs_queues(rabbitmq_settings, agent)
    connected_state = put_connected_resources(state, connection, channel)

    case consume_queues(channel, queues) do
      :ok ->
        Logger.info(
          "[Agent] Connected to RabbitMQ at #{GSMLG.Scout.RabbitMQ.redact_url(rabbitmq_settings["url"])}"
        )

        {:noreply, connected_state}

      {:error, reason} ->
        retry_after_consume_failure(connected_state, connection, channel, reason)
    end
  rescue
    exception ->
      retry_after_consume_failure(state, connection, channel, exception)
  catch
    kind, reason ->
      retry_after_consume_failure(state, connection, channel, {kind, reason})
  end

  defp jobs_queues(rabbitmq_settings, agent) do
    global_queue = rabbitmq_settings["queues"]["jobs"]
    regional_queue = rabbitmq_settings["regional_queues"][agent["region"]]

    [global_queue, regional_queue]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp consume_queues(channel, queues) do
    with :ok <- configure_qos(channel) do
      Enum.reduce_while(queues, :ok, fn queue, :ok ->
        case basic().consume(channel, queue, nil, no_ack: false) do
          {:ok, _consumer_tag} ->
            Logger.info("[Agent] Consuming from queue: #{queue}")
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, reason}}

          reason ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp configure_qos(channel) do
    case basic().qos(channel, prefetch_count: prefetch_count()) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp retry_after_consume_failure(state, connection, channel, reason) do
    close_resources(%{state | connection: connection, channel: channel})
    {:noreply, state |> Map.put(:last_error, reason) |> schedule_retry()}
  end

  defp handle_resource_down(state, reason) do
    close_resources(state)

    {:noreply,
     state
     |> Map.put(:last_error, {:resource_down, reason})
     |> schedule_retry()}
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :connect, retry_delay_ms())

    %{
      state
      | connection: nil,
        channel: nil,
        connection_ref: nil,
        channel_ref: nil
    }
  end

  defp dispatch_delivery(_payload, _delivery_tag, nil), do: {:error, :channel_not_connected}

  defp dispatch_delivery(payload, delivery_tag, channel) do
    case Process.whereis(GSMLG.Scout.Agent.TaskSupervisor) do
      nil ->
        {:error, :task_supervisor_not_running}

      _pid ->
        case Task.Supervisor.start_child(GSMLG.Scout.Agent.TaskSupervisor, fn ->
               process_delivery(payload, delivery_tag, channel)
             end) do
          {:ok, _pid} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp process_delivery(payload, delivery_tag, channel) do
    result = build_result(payload)

    Logger.info("[Agent] Job completed (ok: #{result.ok}), publishing result")

    case publish_result(result) do
      :ok ->
        safe_ack(channel, delivery_tag)

      {:error, reason} ->
        Logger.error("[Agent] Failed to publish result: #{inspect(reason)}")
        safe_nack(channel, delivery_tag)

      reason ->
        Logger.error("[Agent] Failed to publish result: #{inspect(reason)}")
        safe_nack(channel, delivery_tag)
    end
  rescue
    exception ->
      Logger.error("[Agent] Failed to process delivery: #{Exception.message(exception)}")
      safe_nack(channel, delivery_tag)
  catch
    kind, reason ->
      Logger.error("[Agent] Failed to process delivery: #{inspect({kind, reason})}")
      safe_nack(channel, delivery_tag)
  end

  defp build_result(payload) do
    result =
      with {:ok, map} <- Jason.decode(payload),
           {:ok, job} <- Job.from_map(map) do
        Logger.info("[Agent] Starting fetch for URL: #{job.url} (job_id: #{job.job_id})")
        safe_fetch(job)
      else
        error ->
          Logger.error("[Agent] Failed to decode job payload: #{inspect(error)}")

          %Result{
            job_id: nil,
            ok: false,
            url: nil,
            error: %{type: "invalid_job", message: inspect(error), retryable: false}
          }
      end

    result
  end

  defp safe_fetch(job) do
    Agent.fetch(job)
  rescue
    exception ->
      Result.failure(job, %{
        type: "fetch_failed",
        message: Exception.message(exception),
        retryable: true
      })
  catch
    kind, reason ->
      Result.failure(job, %{
        type: "fetch_failed",
        message: inspect({kind, reason}),
        retryable: true
      })
  end

  defp publish_result(result) do
    case rabbitmq().publish_result(result) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      reason -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_ack(channel, delivery_tag) do
    basic().ack(channel, delivery_tag)
    :ok
  rescue
    exception ->
      Logger.error(
        "[Agent] Failed to ack delivery #{inspect(delivery_tag)}: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "[Agent] Failed to ack delivery #{inspect(delivery_tag)}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp safe_nack(channel, delivery_tag) do
    basic().nack(channel, delivery_tag, requeue: true)
    :ok
  rescue
    exception ->
      Logger.error(
        "[Agent] Failed to nack delivery #{inspect(delivery_tag)}: #{Exception.message(exception)}"
      )

      :ok
  catch
    kind, reason ->
      Logger.error(
        "[Agent] Failed to nack delivery #{inspect(delivery_tag)}: #{inspect({kind, reason})}"
      )

      :ok
  end

  defp retry_delay_ms do
    Application.get_env(:gsmlg_scout_agent, :consumer_retry_delay_ms, @default_retry_delay_ms)
  end

  defp prefetch_count do
    Settings.get()["agent"]["browser_instances"]
    |> normalize_positive_integer(1)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp rabbitmq do
    Application.get_env(:gsmlg_scout_agent, :rabbitmq, GSMLG.Scout.RabbitMQ)
  end

  defp amqp_modules do
    %{channel: AMQP.Channel, connection: AMQP.Connection}
    |> Map.merge(Application.get_env(:gsmlg_scout, :amqp_modules, %{}))
    |> Map.merge(Application.get_env(:gsmlg_scout_agent, :amqp_modules, %{}))
  end

  defp basic do
    Application.get_env(:gsmlg_scout_agent, :amqp_basic, AMQP.Basic)
  end

  defp put_connected_resources(state, connection, channel) do
    %{
      state
      | connection: connection,
        channel: channel,
        connection_ref: monitor_resource(connection),
        channel_ref: monitor_resource(channel),
        last_error: nil
    }
  end

  defp monitor_resource(resource) when is_pid(resource), do: Process.monitor(resource)
  defp monitor_resource(_resource), do: nil

  defp demonitor_resource(nil), do: :ok

  defp demonitor_resource(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp close_resources(state) do
    modules = amqp_modules()

    demonitor_resource(state.channel_ref)
    demonitor_resource(state.connection_ref)

    safe_close(fn -> close_channel(modules, state.channel) end)
    safe_close(fn -> close_connection(modules, state.connection) end)
  end

  defp close_channel(_modules, nil), do: :ok
  defp close_channel(modules, channel), do: modules.channel.close(channel)

  defp close_connection(_modules, nil), do: :ok
  defp close_connection(modules, connection), do: modules.connection.close(connection)

  defp safe_close(close_fun) do
    close_fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end
end
