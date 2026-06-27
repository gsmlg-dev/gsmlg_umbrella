defmodule GSMLG.Scout.RabbitMQTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Fetch.Job
  alias GSMLG.Scout.RabbitMQ

  setup do
    previous_settings = Application.get_env(:gsmlg_scout, :settings)
    previous_modules = Application.get_env(:gsmlg_scout, :amqp_modules)
    previous_pid = Application.get_env(:gsmlg_scout, :amqp_test_pid)

    on_exit(fn ->
      restore_env(:settings, previous_settings)
      restore_env(:amqp_modules, previous_modules)
      restore_env(:amqp_test_pid, previous_pid)
    end)

    :ok
  end

  test "redacts credentials from AMQP URLs" do
    redacted = RabbitMQ.redact_url("amqp://user:secret@rabbitmq:5672/vhost")

    refute redacted =~ "secret"
    refute redacted =~ "user:secret"
    assert redacted == "amqp://[REDACTED]@rabbitmq:5672/vhost"
  end

  test "returns URLs without userinfo safely" do
    assert RabbitMQ.redact_url("amqp://rabbitmq:5672/vhost") == "amqp://rabbitmq:5672/vhost"
  end

  test "returns JSON encode errors without opening a connection" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.TrackingConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.SuccessfulQueue,
      basic: __MODULE__.FakeBasic
    })

    assert {:error, {:json_encode, _reason}} = RabbitMQ.publish_heartbeat(%{pid: self()})
    refute_received :connection_opened
  end

  test "publishes jobs with expected queue JSON body and options" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.SuccessfulQueue,
      basic: __MODULE__.CapturingBasic
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert :ok = RabbitMQ.publish_job(job)

    assert_received {:published, "scout.fetch.jobs", body,
                     [persistent: true, content_type: "application/json"]}

    assert {:ok, payload} = Jason.decode(body)
    assert payload["job_id"] == "job-1"
    assert payload["url"] == "https://example.com/docs"
    assert_received {:closed, :channel}
    assert_received {:closed, :connection}
  end

  test "closes opened channel and connection when queue declaration fails" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.FakeQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert {:error, :declare_failed} = RabbitMQ.publish_job(job)
    assert_received {:closed, :channel}
    assert_received {:closed, :connection}
  end

  test "closes opened channel and connection when queue declaration raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.RaisingQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert {:error, %RuntimeError{message: "declare exploded"}} = RabbitMQ.publish_job(job)
    assert_received {:closed, :channel}
    assert_received {:closed, :connection}
  end

  test "closes opened connection when channel open raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.RaisingChannel,
      queue: __MODULE__.SuccessfulQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert {:error, %RuntimeError{message: "channel exploded"}} = RabbitMQ.publish_job(job)
    assert_received {:closed, :connection}
  end

  test "closes connection and preserves original error when channel close raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.CloseRaisingChannel,
      queue: __MODULE__.FakeQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert {:error, :declare_failed} = RabbitMQ.publish_job(job)
    assert_received {:closed, :connection}
  end

  test "open_channel closes opened connection when channel open raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.RaisingChannel,
      queue: __MODULE__.SuccessfulQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    assert {:error, %RuntimeError{message: "channel exploded"}} = RabbitMQ.open_channel()
    assert_received {:closed, :connection}
  end

  test "open_channel closes opened channel and connection when queue declaration raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.RaisingQueue,
      basic: __MODULE__.FakeBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    assert {:error, %RuntimeError{message: "declare exploded"}} = RabbitMQ.open_channel()
    assert_received {:closed, :channel}
    assert_received {:closed, :connection}
  end

  test "closes opened channel and connection when publishing raises" do
    Application.put_env(:gsmlg_scout, :amqp_test_pid, self())

    Application.put_env(:gsmlg_scout, :amqp_modules, %{
      connection: __MODULE__.FakeConnection,
      channel: __MODULE__.FakeChannel,
      queue: __MODULE__.SuccessfulQueue,
      basic: __MODULE__.RaisingBasic
    })

    Application.put_env(:gsmlg_scout, :settings, %{
      rabbitmq: %{url: "amqp://user:secret@rabbitmq:5672/vhost"}
    })

    job = %Job{job_id: "job-1", url: "https://example.com/docs"}

    assert {:error, %RuntimeError{message: "publish exploded"}} = RabbitMQ.publish_job(job)
    assert_received {:closed, :channel}
    assert_received {:closed, :connection}
  end

  defp restore_env(key, nil), do: Application.delete_env(:gsmlg_scout, key)
  defp restore_env(key, value), do: Application.put_env(:gsmlg_scout, key, value)

  defmodule FakeConnection do
    def open(_url), do: {:ok, :connection}

    def close(:connection) do
      send(Application.fetch_env!(:gsmlg_scout, :amqp_test_pid), {:closed, :connection})
      :ok
    end
  end

  defmodule TrackingConnection do
    def open(_url) do
      send(Application.fetch_env!(:gsmlg_scout, :amqp_test_pid), :connection_opened)
      {:ok, :connection}
    end

    def close(:connection) do
      send(Application.fetch_env!(:gsmlg_scout, :amqp_test_pid), {:closed, :connection})
      :ok
    end
  end

  defmodule FakeChannel do
    def open(:connection), do: {:ok, :channel}

    def close(:channel) do
      send(Application.fetch_env!(:gsmlg_scout, :amqp_test_pid), {:closed, :channel})
      :ok
    end
  end

  defmodule RaisingChannel do
    def open(:connection), do: raise("channel exploded")
  end

  defmodule CloseRaisingChannel do
    def open(:connection), do: {:ok, :channel}
    def close(:channel), do: raise("channel close exploded")
  end

  defmodule FakeQueue do
    def declare(:channel, _queue, _opts), do: {:error, :declare_failed}
  end

  defmodule SuccessfulQueue do
    def declare(:channel, _queue, _opts), do: {:ok, :queue}
  end

  defmodule RaisingQueue do
    def declare(:channel, _queue, _opts), do: raise("declare exploded")
  end

  defmodule FakeBasic do
    def publish(_channel, _exchange, _queue, _body, _opts), do: :ok
  end

  defmodule CapturingBasic do
    def publish(:channel, "", queue, body, opts) do
      send(Application.fetch_env!(:gsmlg_scout, :amqp_test_pid), {:published, queue, body, opts})
      :ok
    end
  end

  defmodule RaisingBasic do
    def publish(_channel, _exchange, _queue, _body, _opts), do: raise("publish exploded")
  end
end
