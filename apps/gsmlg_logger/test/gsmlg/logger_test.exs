defmodule GSMLG.LoggerTest do
  use ExUnit.Case

  describe "configure_log_level_from_env/1" do
    test "configures log level from environment variable" do
      System.put_env("GSMLG_LOGGER_TEST_LOG_LEVEL", "warning")
      assert GSMLG.Logger.configure_log_level_from_env!("GSMLG_LOGGER_TEST_LOG_LEVEL") == :ok
      assert Logger.level() == :warning
    end
  end

  describe "configure_log_level/1" do
    test "configures log level" do
      assert GSMLG.Logger.configure_log_level!("debug") == :ok
      assert Logger.level() == :debug

      assert GSMLG.Logger.configure_log_level!(:info) == :ok
      assert Logger.level() == :info

      assert GSMLG.Logger.configure_log_level!(nil) == :ok
      assert Logger.level() == :info
    end

    test "raises on invalid log level" do
      message =
        "Log level should be one of 'debug', 'info', 'warn', 'error' values, got: :invalid"

      assert_raise ArgumentError, message, fn ->
        GSMLG.Logger.configure_log_level!(:invalid)
      end
    end
  end
end
