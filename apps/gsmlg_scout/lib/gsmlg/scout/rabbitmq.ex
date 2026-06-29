defmodule GSMLG.Scout.RabbitMQ do
  @moduledoc """
  RabbitMQ publisher helpers for Scout jobs, results, failures, and heartbeats.
  """

  alias GSMLG.Scout.Fetch.{Job, Result}
  alias GSMLG.Scout.Settings
  require Logger

  @default_amqp_modules %{
    connection: AMQP.Connection,
    channel: AMQP.Channel,
    queue: AMQP.Queue,
    basic: AMQP.Basic
  }

  def enabled? do
    Settings.get()["rabbitmq"]["enabled"]
  end

  def publish_job(%Job{} = job) do
    publish(queue("jobs", job.region_hint), Job.to_map(job))
  end

  def publish_result(%Result{ok: true} = result) do
    publish(queue("results"), Result.to_map(result))
  end

  def publish_result(%Result{} = result) do
    publish(queue("failed"), Result.to_map(result))
  end

  def publish_heartbeat(payload) do
    publish(queue("heartbeat"), payload)
  end

  def open_channel do
    config = Settings.get()["rabbitmq"]
    modules = amqp_modules()
    Logger.info("[RabbitMQ] Opening connection to #{redact_url(config["url"])}")

    case open_connection(modules, config["url"]) do
      {:ok, connection} ->
        open_channel_with_connection(modules, connection)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def redact_url(url) when is_binary(url) do
    uri = URI.parse(url)

    case uri.userinfo do
      nil -> url
      "" -> url
      _userinfo -> URI.to_string(%{uri | userinfo: "[REDACTED]"})
    end
  end

  def redact_url(url), do: url

  defp publish(queue, payload) do
    config = Settings.get()["rabbitmq"]
    modules = amqp_modules()

    with {:ok, body} <- encode_payload(payload),
         {:ok, connection} <- open_connection(modules, config["url"]) do
      publish_with_connection(modules, connection, queue, body)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp encode_payload(payload) do
    case Jason.encode(payload) do
      {:ok, body} -> {:ok, body}
      {:error, reason} -> {:error, {:json_encode, reason}}
    end
  end

  defp declare_known_queues(modules, channel) do
    settings = Settings.get()["rabbitmq"]

    settings["queues"]
    |> Map.values()
    |> Kernel.++(Map.values(settings["regional_queues"]))
    |> Enum.reduce_while(:ok, fn queue, :ok ->
      case modules.queue.declare(channel, queue, durable: true) do
        {:ok, _queue} -> {:cont, :ok}
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        error -> {:halt, {:error, error}}
      end
    end)
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp open_connection(modules, url) do
    case modules.connection.open(url) do
      {:ok, connection} -> {:ok, connection}
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp open_channel_with_connection(modules, connection) do
    case open_amqp_channel(modules, connection) do
      {:ok, channel} ->
        case declare_known_queues(modules, channel) do
          :ok ->
            Logger.info("[RabbitMQ] Connection established and channel opened")
            {:ok, connection, channel}

          {:error, reason} ->
            cleanup({:error, reason}, modules, channel, connection)
        end

      {:error, reason} ->
        cleanup({:error, reason}, modules, nil, connection)
    end
  end

  defp publish_with_connection(modules, connection, queue, body) do
    case open_amqp_channel(modules, connection) do
      {:ok, channel} ->
        publish_with_channel(modules, connection, channel, queue, body)

      {:error, reason} ->
        cleanup({:error, reason}, modules, nil, connection)
    end
  end

  defp open_amqp_channel(modules, connection) do
    case modules.channel.open(connection) do
      {:ok, channel} -> {:ok, channel}
      {:error, reason} -> {:error, reason}
      error -> {:error, error}
    end
  rescue
    exception -> {:error, exception}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp publish_with_channel(modules, connection, channel, queue, body) do
    result =
      try do
        with {:ok, _} <- modules.queue.declare(channel, queue, durable: true),
             :ok <-
               modules.basic.publish(channel, "", queue, body,
                 persistent: true,
                 content_type: "application/json"
               ) do
          :ok
        else
          {:error, reason} -> {:error, reason}
          error -> {:error, error}
        end
      rescue
        exception -> {:error, exception}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    cleanup(result, modules, channel, connection)
  end

  defp cleanup(result, modules, channel, connection) do
    safe_close(fn -> close_channel(modules, channel) end)
    safe_close(fn -> modules.connection.close(connection) end)
    result
  end

  defp close_channel(_modules, nil), do: :ok
  defp close_channel(modules, channel), do: modules.channel.close(channel)

  defp safe_close(close_fun) do
    close_fun.()
    :ok
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp amqp_modules do
    @default_amqp_modules
    |> Map.merge(Application.get_env(:gsmlg_scout, :amqp_modules, %{}))
    |> Map.new(fn {key, module} -> {key, module} end)
  end

  defp queue(name, region_hint \\ nil)

  defp queue("jobs", region_hint) when is_binary(region_hint) do
    settings = Settings.get()["rabbitmq"]
    settings["regional_queues"][region_hint] || settings["queues"]["jobs"]
  end

  defp queue(name, _region_hint) do
    Settings.get()["rabbitmq"]["queues"][name]
  end
end
