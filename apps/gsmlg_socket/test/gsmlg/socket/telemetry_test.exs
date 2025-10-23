defmodule GSMLG.Socket.TelemetryTest do
  use ExUnit.Case, async: true
  doctest GSMLG.Socket.Telemetry

  alias GSMLG.Socket.Telemetry

  describe "span/3" do
    test "executes function and returns result" do
      result =
        Telemetry.span(:test_operation, %{test: true}, fn ->
          {:ok, %{}}
        end)

      assert result == :ok
    end

    test "handles function returning value with metadata" do
      result =
        Telemetry.span(:test_operation, %{test: true}, fn ->
          {{:ok, :value}, %{additional: :metadata}}
        end)

      assert result == {:ok, :value}
    end

    test "captures exceptions" do
      assert_raise RuntimeError, "test error", fn ->
        Telemetry.span(:test_operation, %{test: true}, fn ->
          raise "test error"
        end)
      end
    end
  end

  describe "log_connection/3" do
    test "logs connection event" do
      assert :ok = Telemetry.log_connection(:tcp, :connect, %{host: "example.com", port: 80})
    end

    test "logs close event with debug level" do
      assert :ok = Telemetry.log_connection(:tcp, :close, %{})
    end
  end

  describe "log_error/3" do
    test "logs error with metadata" do
      assert :ok =
               Telemetry.log_error(:tcp, "Connection failed", %{reason: :econnrefused})
    end
  end

  describe "log_security/2" do
    test "logs security event" do
      assert :ok =
               Telemetry.log_security("SSL handshake failed", %{
                 host: "example.com",
                 error: :handshake_failure
               })
    end
  end

  describe "log_data_transfer/4" do
    test "logs data transfer metrics" do
      assert :ok = Telemetry.log_data_transfer(:tcp, :send, 1024, %{})
    end
  end
end
