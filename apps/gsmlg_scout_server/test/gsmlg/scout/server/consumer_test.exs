defmodule GSMLG.Scout.Server.ConsumerTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Server.{HeartbeatConsumer, ResultConsumer}

  setup do
    previous_settings = Application.get_env(:gsmlg_scout, :settings)
    previous_amqp_modules = Application.get_env(:gsmlg_scout, :amqp_modules)
    previous_rabbitmq = Application.get_env(:gsmlg_scout_server, :rabbitmq)
    previous_basic = Application.get_env(:gsmlg_scout_server, :amqp_basic)
    previous_retry_delay = Application.get_env(:gsmlg_scout_server, :consumer_retry_delay_ms)
    previous_publisher = Application.get_env(:gsmlg_scout_server, :job_publisher)
    previous_test_pid = Application.get_env(:gsmlg_scout_server, :test_pid)

    Application.put_env(:gsmlg_scout_server, :consumer_retry_delay_ms, 10)
    Application.put_env(:gsmlg_scout_server, :test_pid, self())
    reset_server_state()

    on_exit(fn ->
      Application.stop(:gsmlg_scout_server)

      restore_scout_env(:settings, previous_settings)
      restore_scout_env(:amqp_modules, previous_amqp_modules)
      restore_server_env(:rabbitmq, previous_rabbitmq)
      restore_server_env(:amqp_basic, previous_basic)
      restore_server_env(:consumer_retry_delay_ms, previous_retry_delay)
      restore_server_env(:job_publisher, previous_publisher)
      restore_server_env(:test_pid, previous_test_pid)

      {:ok, _apps} = Application.ensure_all_started(:gsmlg_scout_server)
    end)

    :ok
  end

  test "server application starts when RabbitMQ is enabled but broker connection fails" do
    :ok = Application.stop(:gsmlg_scout_server)

    Application.put_env(:gsmlg_scout, :settings, %{
      "rabbitmq" => %{"enabled" => true}
    })

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FailingConnection
    })

    assert :ok = Application.start(:gsmlg_scout_server)
    assert Process.whereis(GSMLG.Scout.Server.JobManager)
  end

  test "heartbeat consumer stays alive when consume fails" do
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.FailingBasic)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.ClosingConnection,
      channel: __MODULE__.ClosingChannel
    })

    assert {:ok, pid} = HeartbeatConsumer.start_link(queue: "heartbeat")
    on_exit(fn -> stop_if_alive(pid) end)

    assert Process.alive?(pid)
    assert %{last_error: :consume_failed} = :sys.get_state(pid)
    assert_receive {:closed_channel, :channel}
    assert_receive {:closed_connection, :connection}
  end

  test "result consumer closes opened handles when consume fails" do
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.FailingBasic)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.ClosingConnection,
      channel: __MODULE__.ClosingChannel
    })

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    on_exit(fn -> stop_if_alive(pid) end)

    assert Process.alive?(pid)
    assert %{last_error: :consume_failed} = :sys.get_state(pid)
    assert_receive {:closed_channel, :channel}
    assert_receive {:closed_connection, :connection}
  end

  test "result consumer stays alive when channel open fails" do
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.FailingRabbitMQ)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FailingConnection
    })

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    on_exit(fn -> stop_if_alive(pid) end)

    assert Process.alive?(pid)
    assert %{last_error: :connection_failed} = :sys.get_state(pid)
  end

  test "result consumer preserves retryable JSON errors from RabbitMQ payloads" do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.QueueOnlyPublisher)
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.OpenBasic)

    Application.put_env(:gsmlg_scout, :settings, %{
      "fetch" => %{
        "retry" => %{
          "max_attempts" => 2,
          "base_backoff_ms" => 500,
          "max_backoff_ms" => 500,
          "jitter" => false
        }
      }
    })

    assert {:ok, %{job_id: job_id}} =
             GSMLG.Scout.Server.submit_fetch(%{"url" => "https://example.com/rabbitmq-retry"})

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    on_exit(fn -> stop_if_alive(pid) end)

    send(pid, {:basic_deliver, retryable_failure_payload(job_id), %{delivery_tag: 1}})

    assert_eventually(fn ->
      assert {:ok, %{status: "retrying", next_attempt_ms: 500}} =
               GSMLG.Scout.Server.get_fetch(job_id)
    end)
  end

  test "consumer ignores stale connect messages once connected" do
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.CountingRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.OpenBasic)

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    on_exit(fn -> stop_if_alive(pid) end)

    assert_receive {:open_channel, 1}
    send(pid, :connect)
    refute_receive {:open_channel, 2}, 50
  end

  test "result consumer closes opened handles on basic cancel" do
    Application.put_env(:gsmlg_scout_server, :consumer_retry_delay_ms, 1_000)
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.OpenBasic)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      channel: __MODULE__.ClosingChannel,
      connection: __MODULE__.ClosingConnection
    })

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    on_exit(fn -> stop_if_alive(pid) end)
    assert_receive {:consumed, :channel}

    send(pid, {:basic_cancel, %{}})

    assert_receive {:closed_channel, :channel}
    assert_receive {:closed_connection, :connection}
    assert %{last_error: :basic_cancel, connection: nil, channel: nil} = :sys.get_state(pid)
  end

  test "heartbeat consumer closes opened handles on basic cancel" do
    Application.put_env(:gsmlg_scout_server, :consumer_retry_delay_ms, 1_000)
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.OpenBasic)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      channel: __MODULE__.ClosingChannel,
      connection: __MODULE__.ClosingConnection
    })

    assert {:ok, pid} = HeartbeatConsumer.start_link(queue: "heartbeat")
    on_exit(fn -> stop_if_alive(pid) end)
    assert_receive {:consumed, :channel}

    send(pid, {:basic_cancel, %{}})

    assert_receive {:closed_channel, :channel}
    assert_receive {:closed_connection, :connection}
    assert %{last_error: :basic_cancel, connection: nil, channel: nil} = :sys.get_state(pid)
  end

  test "consumer closes injected channel and connection modules on shutdown" do
    Application.put_env(:gsmlg_scout_server, :rabbitmq, __MODULE__.OpenRabbitMQ)
    Application.put_env(:gsmlg_scout_server, :amqp_basic, __MODULE__.OpenBasic)

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      channel: __MODULE__.ClosingChannel,
      connection: __MODULE__.ClosingConnection
    })

    assert {:ok, pid} = ResultConsumer.start_link(queue: "results")
    assert_receive {:consumed, :channel}

    GenServer.stop(pid)

    assert_receive {:closed_channel, :channel}
    assert_receive {:closed_connection, :connection}
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp retryable_failure_payload(job_id) do
    Jason.encode!(%{
      "job_id" => job_id,
      "ok" => false,
      "url" => "https://example.com/rabbitmq-retry",
      "error" => %{
        "type" => "temporary_network_failure",
        "message" => "temporary failure",
        "retryable" => true
      }
    })
  end

  defp assert_eventually(callback, attempts \\ 20)

  defp assert_eventually(callback, attempts) when attempts > 0 do
    callback.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(callback, attempts - 1)
  end

  defp assert_eventually(callback, 0), do: callback.()

  defp reset_server_state do
    :ok = GSMLG.Scout.Server.JobManager.reset()
    :ok = GSMLG.Scout.Server.AgentRegistry.reset()
  end

  defp restore_scout_env(key, nil), do: Application.delete_env(:gsmlg_scout, key)
  defp restore_scout_env(key, value), do: Application.put_env(:gsmlg_scout, key, value)

  defp restore_server_env(key, nil), do: Application.delete_env(:gsmlg_scout_server, key)
  defp restore_server_env(key, value), do: Application.put_env(:gsmlg_scout_server, key, value)

  defmodule FailingRabbitMQ do
    def open_channel, do: {:error, :connection_failed}
  end

  defmodule OpenRabbitMQ do
    def open_channel, do: {:ok, :connection, :channel}
  end

  defmodule CountingRabbitMQ do
    def open_channel do
      count = Process.get(:open_channel_count, 0) + 1
      Process.put(:open_channel_count, count)
      send(test_pid(), {:open_channel, count})
      {:ok, :connection, :channel}
    end

    defp test_pid do
      Application.fetch_env!(:gsmlg_scout_server, :test_pid)
    end
  end

  defmodule FailingBasic do
    def consume(_channel, _queue, _consumer, _opts), do: {:error, :consume_failed}
  end

  defmodule OpenBasic do
    def consume(channel, _queue, _consumer, _opts) do
      send(test_pid(), {:consumed, channel})
      {:ok, "consumer-tag"}
    end

    def ack(_channel, _delivery_tag), do: :ok

    defp test_pid do
      Application.fetch_env!(:gsmlg_scout_server, :test_pid)
    end
  end

  defmodule QueueOnlyPublisher do
    def publish_job(_job), do: :ok
  end

  defmodule ClosingChannel do
    def close(channel) do
      send(test_pid(), {:closed_channel, channel})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:gsmlg_scout_server, :test_pid)
    end
  end

  defmodule ClosingConnection do
    def close(connection) do
      send(test_pid(), {:closed_connection, connection})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:gsmlg_scout_server, :test_pid)
    end
  end

  defmodule FailingConnection do
    def open(_url), do: {:error, :connection_failed}
  end

  defmodule OpenConnection do
    def open(_url), do: {:ok, :connection}
    def close(_connection), do: :ok
  end

  defmodule OpenChannel do
    def open(_connection), do: {:ok, :channel}
    def close(_channel), do: :ok
  end

  defmodule OpenQueue do
    def declare(_channel, _queue, _opts), do: {:ok, :queue}
  end
end
