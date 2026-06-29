defmodule GSMLG.Scout.Server.ResultConsumer do
  @moduledoc """
  RabbitMQ consumer for fetch results emitted by Scout agents.
  """

  use GenServer

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server.ResultHandler
  alias GSMLG.Scout.Settings

  @default_retry_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: name(opts))
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :queue)},
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  @impl true
  def init(opts) do
    state = %{
      queue: Keyword.fetch!(opts, :queue),
      connection: nil,
      channel: nil,
      last_error: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, %{channel: nil} = state), do: connect(state)

  def handle_continue(:connect, state), do: {:noreply, state}

  @impl true
  def handle_info(:connect, %{channel: nil} = state), do: connect(state)

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info({:basic_consume_ok, _meta}, state), do: {:noreply, state}

  def handle_info({:basic_cancel, _meta}, state) do
    close_resources(state)

    {:noreply,
     schedule_retry(%{state | connection: nil, channel: nil, last_error: :basic_cancel})}
  end

  def handle_info({:basic_cancel_ok, _meta}, state), do: {:noreply, state}

  @impl true
  def handle_info({:basic_deliver, payload, meta}, state) do
    with {:ok, map} <- Jason.decode(payload) do
      map
      |> normalize_result_payload()
      |> Result.from_map()
      |> ResultHandler.handle_result()
    end

    basic().ack(state.channel, meta.delivery_tag)
    {:noreply, state}
  end

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
    queue = Settings.get()["rabbitmq"]["queues"][state.queue]

    case basic().consume(channel, queue, nil, no_ack: false) do
      {:ok, _consumer_tag} ->
        {:noreply, %{state | connection: connection, channel: channel, last_error: nil}}

      {:error, reason} ->
        retry_after_consume_failure(state, connection, channel, reason)

      reason ->
        retry_after_consume_failure(state, connection, channel, reason)
    end
  rescue
    exception ->
      retry_after_consume_failure(state, connection, channel, exception)
  catch
    kind, reason ->
      retry_after_consume_failure(state, connection, channel, {kind, reason})
  end

  defp retry_after_consume_failure(state, connection, channel, reason) do
    close_resources(%{state | connection: connection, channel: channel})
    {:noreply, state |> Map.put(:last_error, reason) |> schedule_retry()}
  end

  defp schedule_retry(state) do
    Process.send_after(self(), :connect, retry_delay_ms())
    %{state | connection: nil, channel: nil}
  end

  defp retry_delay_ms do
    # Keep broker outages in the consumer process instead of supervisor restarts.
    Application.get_env(:gsmlg_scout_server, :consumer_retry_delay_ms, @default_retry_delay_ms)
  end

  defp rabbitmq do
    Application.get_env(:gsmlg_scout_server, :rabbitmq, GSMLG.Scout.RabbitMQ)
  end

  defp amqp_modules do
    %{channel: AMQP.Channel, connection: AMQP.Connection}
    |> Map.merge(Application.get_env(:gsmlg_scout, :amqp_modules, %{}))
  end

  defp basic do
    Application.get_env(:gsmlg_scout_server, :amqp_basic, AMQP.Basic)
  end

  defp close_resources(state) do
    modules = amqp_modules()

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

  defp normalize_result_payload(map) when is_map(map) do
    map
    |> normalize_error_key("error")
    |> normalize_error_key(:error)
  end

  defp normalize_error_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, error} -> Map.put(map, key, normalize_error(error))
      :error -> map
    end
  end

  defp normalize_error(error) when is_map(error) do
    %{
      type: error[:type] || error["type"],
      message: error[:message] || error["message"],
      retryable: Map.get(error, :retryable, Map.get(error, "retryable", false))
    }
  end

  defp normalize_error(error), do: error

  defp name(opts), do: :"#{__MODULE__}.#{Keyword.fetch!(opts, :queue)}"
end
