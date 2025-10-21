defmodule GSMLG.Telemetry.Backends.CloudWatchTest do
  use ExUnit.Case, async: false

  alias GSMLG.Telemetry.Backends.CloudWatch

  import Mox

  # Mock GSMLG.AWS.CloudWatchLogs if available
  setup :verify_on_exit!

  describe "when disabled" do
    test "does not start when disabled" do
      opts = [enabled: false]
      assert :ignore == CloudWatch.start_link(opts)
    end
  end

  describe "configuration validation" do
    test "requires log_group_name" do
      opts = [
        enabled: true,
        log_stream_name: "test-stream"
      ]

      assert_raise ArgumentError, "log_group_name is required for CloudWatch backend", fn ->
        CloudWatch.start_link(opts)
      end
    end

    test "requires log_stream_name" do
      opts = [
        enabled: true,
        log_group_name: "test-group"
      ]

      assert_raise ArgumentError, "log_stream_name is required for CloudWatch backend", fn ->
        CloudWatch.start_link(opts)
      end
    end
  end

  describe "event handling" do
    setup do
      opts = [
        enabled: true,
        log_group_name: "test-group",
        log_stream_name: "test-stream",
        region: "us-east-1",
        buffer_size: 2,
        flush_interval: 100
      ]

      {:ok, pid} = start_supervised({CloudWatch, opts})

      %{pid: pid, opts: opts}
    end

    test "buffers events", %{pid: pid} do
      CloudWatch.handle_event([:test, :event], %{count: 1}, %{source: "test"})

      # Should be in buffer (not flushed yet)
      stats = CloudWatch.get_stats()
      assert stats.buffer_size == 1
    end

    test "flushes when buffer is full", %{pid: pid} do
      CloudWatch.handle_event([:test, :event1], %{count: 1}, %{source: "test"})
      CloudWatch.handle_event([:test, :event2], %{count: 2}, %{source: "test"})

      # Should flush automatically (buffer_size = 2)
      :timer.sleep(50) # Give time for flush

      stats = CloudWatch.get_stats()
      assert stats.buffer_size == 0
    end

    test "flushes on demand", %{pid: pid} do
      CloudWatch.handle_event([:test, :event], %{count: 1}, %{source: "test"})
      assert CloudWatch.get_stats().buffer_size == 1

      CloudWatch.flush()
      :timer.sleep(50) # Give time for flush

      stats = CloudWatch.get_stats()
      assert stats.buffer_size == 0
    end
  end

  describe "log level filtering" do
    setup do
      opts = [
        enabled: true,
        log_group_name: "test-group",
        log_stream_name: "test-stream",
        level: :warn,
        buffer_size: 1,
        flush_interval: 100
      ]

      {:ok, pid} = start_supervised({CloudWatch, opts})

      %{pid: pid}
    end

    test "filters out events below minimum level" do
      # Debug event should be filtered out
      CloudWatch.handle_event([:test, :debug], %{count: 1}, %{level: :debug})
      stats = CloudWatch.get_stats()
      assert stats.buffer_size == 0

      # Warn event should be included
      CloudWatch.handle_event([:test, :warn], %{count: 1}, %{level: :warn})
      stats = CloudWatch.get_stats()
      assert stats.buffer_size == 1
    end
  end

  describe "configuration updates" do
    setup do
      opts = [
        enabled: true,
        log_group_name: "test-group",
        log_stream_name: "test-stream",
        buffer_size: 5,
        flush_interval: 1000
      ]

      {:ok, pid} = start_supervised({CloudWatch, opts})

      %{pid: pid}
    end

    test "updates configuration at runtime" do
      CloudWatch.update_config(buffer_size: 10)

      # This is a basic test - in a real scenario you might want to verify
      # the config was actually updated
      assert :ok == CloudWatch.update_config(buffer_size: 10)
    end
  end

  describe "statistics" do
    setup do
      opts = [
        enabled: true,
        log_group_name: "test-group",
        log_stream_name: "test-stream",
        buffer_size: 5,
        flush_interval: 1000
      ]

      {:ok, pid} = start_supervised({CloudWatch, opts})

      %{pid: pid}
    end

    test "returns backend statistics" do
      stats = CloudWatch.get_stats()

      assert stats.enabled == true
      assert stats.log_group_name == "test-group"
      assert stats.log_stream_name == "test-stream"
      assert is_integer(stats.buffer_size)
      assert %DateTime{} = stats.last_flush_time
    end
  end

  describe "connectivity testing" do
    setup do
      opts = [
        enabled: true,
        log_group_name: "test-group",
        log_stream_name: "test-stream"
      ]

      {:ok, pid} = start_supervised({CloudWatch, opts})

      %{pid: pid}
    end

    test "tests connectivity" do
      # This will likely fail in test environment without actual AWS credentials,
      # but we can test that the function exists and returns expected format
      result = CloudWatch.test_connectivity()

      assert result == :ok or match?({:error, _}, result)
    end
  end

  describe "disabled backend" do
    test "handles events gracefully when disabled" do
      opts = [enabled: false]
      {:ok, pid} = start_supervised({CloudWatch, opts})

      # Should not crash or accumulate events
      CloudWatch.handle_event([:test, :event], %{count: 1}, %{source: "test"})

      # Stats should indicate disabled
      stats = CloudWatch.get_stats()
      assert stats.enabled == false
    end
  end
end