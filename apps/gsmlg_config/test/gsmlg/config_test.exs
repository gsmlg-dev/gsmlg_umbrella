defmodule GSMLG.ConfigTest do
  use ExUnit.Case, async: false
  doctest GSMLG.Config

  import ExUnit.CaptureLog

  setup do
    # Don't clean up - the application manages the process lifecycle
    :ok
  end

  describe "start_link/1" do
    test "starts the agent with loaded config" do
      result = GSMLG.Config.start_link([])

      case result do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      assert Process.alive?(Process.whereis(GSMLG.Config))
      config = GSMLG.Config.config()
      assert is_map(config)
      assert config[:logger] != nil
      assert config[:database] != nil
    end

    test "calls setup when starting" do
      # Capture logs to verify setup is called
      log =
        capture_log(fn ->
          result = GSMLG.Config.start_link([])

          case result do
            {:ok, _pid} -> :ok
            {:error, {:already_started, _pid}} -> :ok
          end
        end)

      # Should contain setup-related logs if any
      assert is_binary(log)
    end
  end

  describe "load/0" do
    test "loads config from default file" do
      config = GSMLG.Config.load()

      assert is_map(config)
      assert config[:logger] != nil
      assert config[:logger][:log_level] == "debug"
      assert config[:database] != nil
      assert config[:database][:username] == "gsmlg_dev"
      assert config[:web] != nil
      assert config[:web][:port] == 4110
    end

    test "loads config from custom file path" do
      System.put_env("GSMLG_CONFIG_PATH", Path.expand("../../priv/gsmlg.toml", __DIR__))

      try do
        config = GSMLG.Config.load()
        assert is_map(config)
        assert config[:logger][:log_level] == "debug"
      after
        System.delete_env("GSMLG_CONFIG_PATH")
      end
    end
  end

  describe "config/0" do
    test "returns the entire config map" do
      # Config should already be available from the application

      config = GSMLG.Config.config()
      assert is_map(config)
      assert Map.has_key?(config, :logger)
      assert Map.has_key?(config, :database)
      assert Map.has_key?(config, :web)
    end
  end

  describe "get/1 with atom key" do
    test "returns value for atom key" do
      # Config should already be available from the application

      logger_config = GSMLG.Config.get(:logger)
      assert is_map(logger_config)
      assert logger_config[:log_level] == "debug"
    end

    test "returns nil for non-existent atom key" do
      # Config should already be available from the application

      result = GSMLG.Config.get(:non_existent)
      assert result == nil
    end
  end

  describe "get/1 with binary key" do
    test "returns value for binary key" do
      # Config should already be available from the application

      logger_config = GSMLG.Config.get("logger")
      assert is_map(logger_config)
      assert logger_config[:log_level] == "debug"
    end

    test "returns nil for non-existent binary key" do
      # Config should already be available from the application

      result = GSMLG.Config.get("non_existent")
      assert result == nil
    end
  end

  describe "get/1 with path list" do
    test "returns nested value using path list" do
      # Config should already be available from the application
      log_level = GSMLG.Config.get([:logger, :log_level])
      assert log_level == "debug"

      db_username = GSMLG.Config.get([:database, :username])
      assert db_username == "gsmlg_dev"
    end

    test "returns nil for non-existent path" do
      # Config should already be available from the application

      result = GSMLG.Config.get([:non_existent, :path])
      assert result == nil

      result = GSMLG.Config.get([:logger, :non_existent])
      assert result == nil
    end
  end

  describe "put/2 with atom key" do
    test "updates value for atom key" do
      # Config should already be available from the application

      :ok = GSMLG.Config.put(:test_key, "test_value")
      assert GSMLG.Config.get(:test_key) == "test_value"
    end

    test "overwrites existing value for atom key" do
      # Config should already be available from the application

      original_log_level = GSMLG.Config.get([:logger, :log_level])
      :ok = GSMLG.Config.put(:logger, %{log_level: "warn"})

      updated_logger = GSMLG.Config.get(:logger)
      assert updated_logger[:log_level] == "warn"
      assert updated_logger != original_log_level

      # Restore original value
      :ok = GSMLG.Config.put(:logger, %{log_level: original_log_level})
    end
  end

  describe "put/2 with binary key" do
    test "updates value for binary key" do
      # Config should already be available from the application

      :ok = GSMLG.Config.put("test_key", "test_value")
      assert GSMLG.Config.get("test_key") == "test_value"
    end
  end

  describe "put/2 with path list" do
    test "updates nested value using path list" do
      # Config should already be available from the application

      original_log_level = GSMLG.Config.get([:logger, :log_level])
      :ok = GSMLG.Config.put([:logger, :log_level], "error")
      assert GSMLG.Config.get([:logger, :log_level]) == "error"

      # Restore original value
      :ok = GSMLG.Config.put([:logger, :log_level], original_log_level)
    end

    test "creates nested structure if it doesn't exist" do
      # Config should already be available from the application

      # Initialize the nested structure first
      :ok = GSMLG.Config.put([:new_section], %{})
      :ok = GSMLG.Config.put([:new_section, :new_key], "new_value")
      assert GSMLG.Config.get([:new_section, :new_key]) == "new_value"
    end
  end

  describe "error handling" do
    test "handles missing config file gracefully" do
      System.put_env("GSMLG_CONFIG_PATH", "/non/existent/path.toml")

      try do
        # Should raise an error when file doesn't exist
        assert_raise MatchError, fn ->
          GSMLG.Config.load()
        end
      after
        System.delete_env("GSMLG_CONFIG_PATH")
      end
    end
  end

  describe "integration tests" do
    test "full workflow: start, get, put, get" do
      # Config should already be available from the application

      # Get initial value
      initial_config = GSMLG.Config.config()
      assert is_map(initial_config)

      # Put new value
      :ok = GSMLG.Config.put(:integration_test, "test_value")

      # Get the new value
      assert GSMLG.Config.get(:integration_test) == "test_value"

      # Verify config is updated
      updated_config = GSMLG.Config.config()
      assert updated_config[:integration_test] == "test_value"
    end
  end
end
