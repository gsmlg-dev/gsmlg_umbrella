defmodule GSMLG.Scout.Agent.AMQPConsumerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GSMLG.Scout.Agent.AMQPConsumer
  alias GSMLG.Scout.Fetch.{Job, Result}

  setup do
    previous_agent_env =
      Map.new(
        [:amqp_basic, :amqp_modules, :consumer_retry_delay_ms, :rabbitmq, :test_pid],
        &{&1, Application.get_env(:gsmlg_scout_agent, &1)}
      )

    previous_settings = Application.get_env(:gsmlg_scout, :settings)

    Application.put_env(:gsmlg_scout_agent, :consumer_retry_delay_ms, 10_000)
    Application.put_env(:gsmlg_scout_agent, :test_pid, self())

    Application.put_env(:gsmlg_scout_agent, :amqp_modules, %{
      channel: __MODULE__.Channel,
      connection: __MODULE__.Connection
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      agent: %{
        id: "test-agent-1",
        region: "test",
        heartbeat_interval_ms: 60_000,
        capacity: 4,
        browser_instances: 2
      },
      rabbitmq: %{
        enabled: true,
        url: "amqp://scout:super-secret@rabbitmq.example.test:5672/vhost",
        queues: %{
          jobs: "jobs",
          results: "results",
          failed: "failed",
          heartbeat: "heartbeat"
        }
      }
    })

    on_exit(fn ->
      for {key, value} <- previous_agent_env do
        restore_agent_env(key, value)
      end

      restore_scout_settings(previous_settings)
    end)
  end

  test "connection failure stays in the consumer and schedules retry" do
    pid = start_consumer(__MODULE__.FailingOpenRabbitMQ)

    assert_receive :open_channel

    assert %{
             channel: nil,
             connection: nil,
             last_error: :connection_down
           } = :sys.get_state(pid)
  end

  test "logs redacted RabbitMQ URL after connect" do
    previous_logger_level = Logger.level()
    Logger.configure(level: :info)

    log =
      try do
        capture_log([level: :info], fn ->
          pid = start_consumer(__MODULE__.OpenRabbitMQ)

          assert_receive {:open_channel, :connection, :channel}
          assert_receive {:consume, :channel, "jobs", [no_ack: false]}
          wait_for_connected(pid, :connection, :channel)
        end)
      after
        Logger.configure(level: previous_logger_level)
      end

    assert log =~ "amqp://[REDACTED]@rabbitmq.example.test:5672/vhost"
    refute log =~ "super-secret"
  end

  test "applies channel qos from configured browser_instances before consuming" do
    _pid = start_consumer(__MODULE__.OpenRabbitMQ)

    assert_receive {:open_channel, :connection, :channel}
    assert_receive {:qos, :channel, [prefetch_count: 2]}
    assert_receive {:consume, :channel, "jobs", [no_ack: false]}
  end

  test "consume failure closes resources and keeps the consumer alive for retry" do
    pid = start_consumer(__MODULE__.OpenRabbitMQ, __MODULE__.ConsumeFailingBasic)

    assert_receive {:open_channel, :connection, :channel}
    assert_receive {:consume, :channel, "jobs", [no_ack: false]}
    assert_receive {:channel_closed, :channel}
    assert_receive {:connection_closed, :connection}

    assert %{
             channel: nil,
             connection: nil,
             last_error: :consume_failed
           } = :sys.get_state(pid)
  end

  test "basic cancel closes resources and reconnects later without stopping" do
    pid = start_consumer(__MODULE__.OpenRabbitMQ)

    assert_receive {:open_channel, :connection, :channel}
    assert_receive {:consume, :channel, "jobs", [no_ack: false]}

    send(pid, {:basic_cancel, %{consumer_tag: "consumer-1"}})

    assert_receive {:channel_closed, :channel}
    assert_receive {:connection_closed, :connection}

    assert %{
             channel: nil,
             connection: nil,
             last_error: :basic_cancel
           } = :sys.get_state(pid)
  end

  test "monitored channel down closes resources and reconnects" do
    Application.put_env(:gsmlg_scout_agent, :consumer_retry_delay_ms, 100)

    pid = start_consumer(__MODULE__.OpenProcessRabbitMQ)

    assert_receive {:open_process_channel, connection, channel}
    assert_receive {:consume, ^channel, "jobs", [no_ack: false]}
    wait_for_connected(pid, connection, channel, true)

    Process.exit(channel, :kill)

    assert_receive {:channel_closed, ^channel}
    assert_receive {:connection_closed, ^connection}

    assert %{channel: nil, connection: nil, last_error: {:resource_down, :killed}} =
             :sys.get_state(pid)

    assert_receive {:open_process_channel, next_connection, next_channel}, 300
    assert next_connection != connection
    assert next_channel != channel
  end

  test "monitored connection down closes resources and reconnects" do
    Application.put_env(:gsmlg_scout_agent, :consumer_retry_delay_ms, 100)

    pid = start_consumer(__MODULE__.OpenProcessRabbitMQ)

    assert_receive {:open_process_channel, connection, channel}
    assert_receive {:consume, ^channel, "jobs", [no_ack: false]}
    wait_for_connected(pid, connection, channel, true)

    Process.exit(connection, :kill)

    assert_receive {:channel_closed, ^channel}
    assert_receive {:connection_closed, ^connection}

    assert %{channel: nil, connection: nil, last_error: {:resource_down, :killed}} =
             :sys.get_state(pid)

    assert_receive {:open_process_channel, next_connection, next_channel}, 300
    assert next_connection != connection
    assert next_channel != channel
  end

  test "publish failure nacks and requeues the delivery without acking" do
    pid = start_consumer(__MODULE__.FailingPublishRabbitMQ)

    assert_receive {:open_channel, :connection, :channel}
    assert_receive {:consume, :channel, "jobs", [no_ack: false]}
    wait_for_connected(pid, :connection, :channel)

    send(pid, {:basic_deliver, job_payload(), %{delivery_tag: 41}})

    assert_receive {:publish_attempt, %Result{ok: true}}, 500
    assert_receive {:nack, :channel, 41, [requeue: true]}, 500
    refute_received {:ack, :channel, 41}
  end

  test "delivery handling returns promptly while fetch and publish continue under supervision" do
    pid = start_consumer(__MODULE__.BlockingPublishRabbitMQ)

    assert_receive {:open_channel, :connection, :channel}
    assert_receive {:consume, :channel, "jobs", [no_ack: false]}
    wait_for_connected(pid, :connection, :channel)

    send(pid, {:basic_deliver, job_payload(), %{delivery_tag: 42}})

    assert_receive {:publish_started, publish_pid, %Result{ok: true}}, 500

    probe_pid = self()

    spawn(fn ->
      result =
        try do
          {:ok, :sys.get_state(pid, 100)}
        catch
          :exit, reason -> {:exit, reason}
        end

      send(probe_pid, {:state_probe, result})
    end)

    assert_receive {:state_probe, {:ok, %{channel: :channel}}}, 300
    refute_received {:ack, :channel, 42}

    send(publish_pid, :release_publish)

    assert_receive {:ack, :channel, 42}
  end

  defp start_consumer(rabbitmq, basic \\ __MODULE__.OpenBasic) do
    Application.put_env(:gsmlg_scout_agent, :rabbitmq, rabbitmq)
    Application.put_env(:gsmlg_scout_agent, :amqp_basic, basic)

    start_supervised!({AMQPConsumer, []})
  end

  defp job_payload do
    assert {:ok, job} = Job.new(%{"url" => "https://example.com/docs", "timeout_ms" => 1_000})
    Jason.encode!(Job.to_map(job))
  end

  defp restore_agent_env(key, nil), do: Application.delete_env(:gsmlg_scout_agent, key)
  defp restore_agent_env(key, value), do: Application.put_env(:gsmlg_scout_agent, key, value)

  defp restore_scout_settings(nil), do: Application.delete_env(:gsmlg_scout, :settings)

  defp restore_scout_settings(settings),
    do: Application.put_env(:gsmlg_scout, :settings, settings)

  defp wait_for_connected(pid, connection, channel, require_refs \\ false, attempts \\ 20)

  defp wait_for_connected(pid, connection, channel, require_refs, attempts) when attempts > 0 do
    state = :sys.get_state(pid)

    refs_ready? =
      not require_refs or
        (is_reference(state.connection_ref) and is_reference(state.channel_ref))

    if state.connection == connection and state.channel == channel and refs_ready? do
      state
    else
      Process.sleep(10)
      wait_for_connected(pid, connection, channel, require_refs, attempts - 1)
    end
  end

  defp wait_for_connected(pid, _connection, _channel, _require_refs, 0) do
    flunk("consumer did not reach connected state: #{inspect(:sys.get_state(pid))}")
  end

  defmodule FailingOpenRabbitMQ do
    def open_channel do
      send(test_pid(), :open_channel)
      {:error, :connection_down}
    end

    def publish_result(_result), do: :ok
    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule OpenRabbitMQ do
    def open_channel do
      send(test_pid(), {:open_channel, :connection, :channel})
      {:ok, :connection, :channel}
    end

    def publish_result(result) do
      send(test_pid(), {:publish_attempt, result})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule OpenProcessRabbitMQ do
    def open_channel do
      connection = spawn(fn -> wait_forever() end)
      channel = spawn(fn -> wait_forever() end)

      send(test_pid(), {:open_process_channel, connection, channel})
      {:ok, connection, channel}
    end

    def publish_result(result), do: OpenRabbitMQ.publish_result(result)

    defp wait_forever do
      receive do
        :stop -> :ok
      end
    end

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule FailingPublishRabbitMQ do
    def open_channel, do: OpenRabbitMQ.open_channel()

    def publish_result(result) do
      send(test_pid(), {:publish_attempt, result})
      {:error, :publish_failed}
    end

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule BlockingPublishRabbitMQ do
    def open_channel, do: OpenRabbitMQ.open_channel()

    def publish_result(result) do
      send(test_pid(), {:publish_started, self(), result})

      receive do
        :release_publish -> :ok
      after
        1_000 -> {:error, :publish_timeout}
      end
    end

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule OpenBasic do
    def qos(channel, opts) do
      send(test_pid(), {:qos, channel, opts})
      :ok
    end

    def consume(channel, queue, _consumer, opts) do
      send(test_pid(), {:consume, channel, queue, opts})
      {:ok, "consumer-tag"}
    end

    def ack(channel, tag) do
      send(test_pid(), {:ack, channel, tag})
      :ok
    end

    def nack(channel, tag, opts) do
      send(test_pid(), {:nack, channel, tag, opts})
      :ok
    end

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule ConsumeFailingBasic do
    def qos(channel, opts), do: OpenBasic.qos(channel, opts)

    def consume(channel, queue, _consumer, opts) do
      send(test_pid(), {:consume, channel, queue, opts})
      {:error, :consume_failed}
    end

    def ack(channel, tag), do: OpenBasic.ack(channel, tag)
    def nack(channel, tag, opts), do: OpenBasic.nack(channel, tag, opts)

    defp test_pid, do: Application.fetch_env!(:gsmlg_scout_agent, :test_pid)
  end

  defmodule Channel do
    def close(channel) do
      send(Application.fetch_env!(:gsmlg_scout_agent, :test_pid), {:channel_closed, channel})

      if is_pid(channel) and Process.alive?(channel) do
        Process.exit(channel, :normal)
      end

      :ok
    end
  end

  defmodule Connection do
    def close(connection) do
      send(
        Application.fetch_env!(:gsmlg_scout_agent, :test_pid),
        {:connection_closed, connection}
      )

      if is_pid(connection) and Process.alive?(connection) do
        Process.exit(connection, :normal)
      end

      :ok
    end
  end
end
