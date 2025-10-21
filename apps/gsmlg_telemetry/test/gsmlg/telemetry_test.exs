defmodule GSMLG.TelemetryTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias GSMLG.Telemetry

  describe "log/3" do
    test "logs a message with metadata" do
      :telemetry.attach_many(
        :test_handler,
        [[:gsmlg, :log]],
        &handle_test_event/4,
        %{}
      )

      Telemetry.log(:info, "test message", metadata: %{key: "value"})

      :telemetry.detach(:test_handler)
    end

    test "respects minimum log level" do
      Application.put_env(:gsmlg_telemetry, :level, :warn)

      assert Telemetry.enabled?(:warn)
      refute Telemetry.enabled?(:info)

      Application.delete_env(:gsmlg_telemetry, :level)
    end

    test "emits telemetry event" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :log]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      Telemetry.log(:info, "test message", telemetry_event: [:test, :log])

      assert_receive {:telemetry_event, [:test, :log], measurements, metadata}
      assert measurements.level == :info
      assert metadata.message == "test message"

      :telemetry.detach(:test_handler)
    end
  end

  describe "emit/3" do
    test "emits custom telemetry event" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :custom]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      Telemetry.emit([:test, :custom], %{count: 1}, %{source: "test"})

      assert_receive {:telemetry_event, [:test, :custom], measurements, metadata}
      assert measurements.count == 1
      assert metadata.source == "test"

      :telemetry.detach(:test_handler)
    end
  end

  describe "span/3" do
    test "measures function execution time" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :span]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      result = Telemetry.span([:test, :span], %{operation: "test"}, fn ->
        :timer.sleep(10)
        "success"
      end)

      assert result == "success"

      assert_receive {:telemetry_event, [:test, :span], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == :ok
      assert metadata.operation == "test"

      :telemetry.detach(:test_handler)
    end

    test "handles exceptions in span" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :span]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span([:test, :span], %{operation: "test"}, fn ->
          raise "test error"
        end)
      end

      assert_receive {:telemetry_event, [:test, :span], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == :error
      assert metadata.kind == :exception

      :telemetry.detach(:test_handler)
    end
  end

  describe "span_with_metadata/3" do
    test "returns additional metadata from function" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :span_meta]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      {result, extra_meta} = Telemetry.span_with_metadata([:test, :span_meta], %{base: "meta"}, fn ->
        {"success", %{extra: "metadata", count: 5}}
      end)

      assert result == "success"
      assert extra_meta == %{extra: "metadata", count: 5}

      assert_receive {:telemetry_event, [:test, :span_meta], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == :ok
      assert metadata.base == "meta"
      assert metadata.extra == "metadata"
      assert metadata.count == 5

      :telemetry.detach(:test_handler)
    end

    test "handles function returning just result" do
      test_pid = self()

      :telemetry.attach_many(
        :test_handler,
        [[:test, :span_simple]],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event, measurements, metadata})
        end,
        %{}
      )

      {result, extra_meta} = Telemetry.span_with_metadata([:test, :span_simple], %{base: "meta"}, fn ->
        "success"
      end)

      assert result == "success"
      assert extra_meta == %{}

      assert_receive {:telemetry_event, [:test, :span_simple], measurements, metadata}
      assert measurements.duration > 0
      assert metadata.status == :ok
      assert metadata.base == "meta"

      :telemetry.detach(:test_handler)
    end
  end

  describe "handler management" do
    test "attaches and detaches handlers" do
      assert {:ok, _} = Telemetry.attach_handler(:test_custom, [:test, :handler], __MODULE__, %{})
      assert :ok == Telemetry.detach_handler(:test_custom)
    end

    test "detaching non-existent handler returns error" do
      assert {:error, :not_found} = Telemetry.detach_handler(:non_existent)
    end
  end

  describe "convenience functions" do
    test "debug/2" do
      assert :ok == Telemetry.debug("debug message")
    end

    test "info/2" do
      assert :ok == Telemetry.info("info message")
    end

    test "warn/2" do
      assert :ok == Telemetry.warn("warn message")
    end

    test "error/2" do
      assert :ok == Telemetry.error("error message")
    end
  end

  describe "configuration" do
    test "gets current configuration" do
      config = Telemetry.config()
      assert is_list(config)
    end
  end

  # Helper function for telemetry events
  defp handle_test_event(event, measurements, metadata, _config) do
    send(self(), {:test_event, event, measurements, metadata})
  end
end