defmodule GSMLG_AMQP.Consumer do
  use GenServer
  use AMQP

  def start_link(init_arg) do
    IO.inspect(init_arg)
    GenServer.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @exchange "gen_server_test_exchange"
  @queue "gen_server_test_queue"
  @queue_error "#{@queue}_error"

  @spec publish(binary) :: :ok | {:error, :blocked | :closing}
  def publish(number) do
    case get_chan() do
      chan = %AMQP.Channel{} ->
        Basic.publish(chan, @exchange, "", number)
    end
  end

  @doc """
  Get channel of this process
  """
  def get_chan() do
    case GenServer.call(__MODULE__, :get_chan) do
      {:ok, chan} -> chan
      _ -> nil
    end
  end

  def init(name: name, url: url) do
    # Process.send_after(__MODULE__, :connect, 5_000)
    {:ok, conn} = Connection.open(url)
    {:ok, chan} = Channel.open(conn)
    setup_queue(chan)

    # Limit unacknowledged messages to 10
    :ok = Basic.qos(chan, prefetch_count: 10)
    # Register the GenServer process as a consumer
    {:ok, _consumer_tag} = Basic.consume(chan, @queue)

    {:ok, [name: name, conn: conn, chan: chan]}
  end

  def handle_call(:get_chan, _from, state) do
    {:reply, {:ok, Keyword.get(state, :chan)}, state}
  end

  # Confirmation sent by the broker after registering this process as a consumer
  def handle_info({:basic_consume_ok, %{consumer_tag: consumer_tag}}, chan) do
    IO.inspect(consumer_tag)
    {:noreply, chan}
  end

  # Sent by the broker when the consumer is unexpectedly cancelled (such as after a queue deletion)
  def handle_info({:basic_cancel, %{consumer_tag: consumer_tag}}, chan) do
    IO.inspect(consumer_tag)
    {:stop, :normal, chan}
  end

  # Confirmation sent by the broker to the consumer process after a Basic.cancel
  def handle_info({:basic_cancel_ok, %{consumer_tag: consumer_tag}}, chan) do
    IO.inspect(consumer_tag)
    {:noreply, chan}
  end

  def handle_info({:basic_deliver, payload, %{delivery_tag: tag, redelivered: redelivered}}, chan) do
    # You might want to run payload consumption in separate Tasks in production
    consume(chan, tag, redelivered, payload)
    {:noreply, chan}
  end

  defp setup_queue(chan) do
    {:ok, _} = Queue.declare(chan, @queue_error, durable: true)

    # Messages that cannot be delivered to any consumer in the main queue will be routed to the error queue
    {:ok, _} =
      Queue.declare(chan, @queue,
        durable: true,
        arguments: [
          {"x-dead-letter-exchange", :longstr, ""},
          {"x-dead-letter-routing-key", :longstr, @queue_error}
        ]
      )

    :ok = Exchange.fanout(chan, @exchange, durable: true)
    :ok = Queue.bind(chan, @queue, @exchange)
  end

  defp consume(channel, tag, redelivered, payload) do
    IO.inspect({"consume", channel, tag, redelivered, payload})
    number = String.to_integer(payload)

    if number <= 10 do
      :ok = Basic.ack(channel, tag)
      IO.puts("Consumed a #{number}. tan(#{number}) = #{:math.tan(number)}")
    else
      :ok = Basic.reject(channel, tag, requeue: false)
      IO.puts("#{number} is too big and was rejected.")
    end
  rescue
    # Requeue unless it's a redelivered message.
    # This means we will retry consuming a message once in case of exception
    # before we give up and have it moved to the error queue
    #
    # You might also want to catch :exit signal in production code.
    # Make sure you call ack, nack or reject otherwise consumer will stop
    # receiving messages.
    exception ->
      IO.inspect(exception)
      :ok = Basic.reject(channel, tag, requeue: not redelivered)
      IO.puts("Error converting #{payload} to integer")
  end
end
