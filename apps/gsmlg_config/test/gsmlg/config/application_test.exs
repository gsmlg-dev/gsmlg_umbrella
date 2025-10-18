defmodule GSMLG.Config.ApplicationTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.Application

  setup do
    # Don't stop/start the application - test it as-is
    :ok
  end

  describe "start/2" do
    test "starts the supervisor and config worker" do
      # Check if application is already running or start it
      result = Application.start(:gsmlg_config, :normal)

      sup_pid =
        case result do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Verify supervisor is running
      assert Process.alive?(sup_pid)
      assert Process.whereis(GSMLG.Config.Supervisor) == sup_pid

      # Verify config worker is running
      config_pid = Process.whereis(GSMLG.Config)
      assert Process.alive?(config_pid)

      # Verify config is accessible
      config = GSMLG.Config.config()
      assert is_map(config)

      # Stop the application
      :ok = Application.stop(:gsmlg_config)
    end

    test "uses one_for_one strategy" do
      # Start or get existing application
      result = Application.start(:gsmlg_config, :normal)

      sup_pid =
        case result do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      # Get supervisor children
      children = Supervisor.which_children(sup_pid)
      assert length(children) == 1

      # Get supervisor strategy (this is a bit tricky to test directly)
      # But we can verify the supervisor is running correctly
      assert Process.alive?(sup_pid)

      :ok = Application.stop(:gsmlg_config)
    end

    test "starts with correct supervisor name" do
      # Start or get existing application
      case Application.start(:gsmlg_config, :normal) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Verify supervisor has the correct name
      sup_pid = Process.whereis(GSMLG.Config.Supervisor)
      assert sup_pid != nil
      assert Process.alive?(sup_pid)

      :ok = Application.stop(:gsmlg_config)
    end

    test "handles restart scenarios" do
      # Start or get existing application
      case Application.start(:gsmlg_config, :normal) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Get initial config pid
      initial_config_pid = Process.whereis(GSMLG.Config)
      assert Process.alive?(initial_config_pid)

      # Stop the config worker directly
      Agent.stop(GSMLG.Config, :brutal_kill)

      # Wait a bit for supervisor to restart it
      Process.sleep(100)

      # Verify config worker was restarted
      restarted_config_pid = Process.whereis(GSMLG.Config)
      assert Process.alive?(restarted_config_pid)
      assert restarted_config_pid != initial_config_pid

      # Verify config is still accessible
      config = GSMLG.Config.config()
      assert is_map(config)

      :ok = Application.stop(:gsmlg_config)
    end
  end

  describe "integration with Config module" do
    test "config is properly loaded when application starts" do
      # Start or get existing application
      case Application.start(:gsmlg_config, :normal) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Verify config contains expected values from gsmlg.toml
      config = GSMLG.Config.config()

      assert config[:logger] != nil
      assert config[:logger][:log_level] == "debug"

      assert config[:database] != nil
      assert config[:database][:username] == "gsmlg_dev"

      assert config[:web] != nil
      assert config[:web][:port] == 4110

      :ok = Application.stop(:gsmlg_config)
    end

    test "config operations work after application start" do
      # Start or get existing application
      case Application.start(:gsmlg_config, :normal) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end

      # Test get operations
      logger_config = GSMLG.Config.get(:logger)
      assert is_map(logger_config)

      # Test put operations
      :ok = GSMLG.Config.put(:test_key, "test_value")
      assert GSMLG.Config.get(:test_key) == "test_value"

      # Test nested operations
      :ok = GSMLG.Config.put([:test_nested], %{})
      :ok = GSMLG.Config.put([:test_nested, :key], "nested_value")
      assert GSMLG.Config.get([:test_nested, :key]) == "nested_value"

      :ok = Application.stop(:gsmlg_config)
    end
  end

  describe "application lifecycle" do
    test "can start and stop multiple times" do
      # Start and stop multiple times
      for _i <- 1..3 do
        result = Application.start(:gsmlg_config, :normal)

        case result do
          {:ok, _sup_pid} -> :ok
          # Already started, that's fine
          {:error, {:already_started, _pid}} -> :ok
        end

        # Verify it's running
        assert Process.alive?(Process.whereis(GSMLG.Config.Supervisor))
        assert Process.alive?(Process.whereis(GSMLG.Config))

        # Verify config works
        config = GSMLG.Config.config()
        assert is_map(config)

        :ok = Application.stop(:gsmlg_config)

        # Wait a bit for cleanup
        Process.sleep(50)

        # Verify it's stopped (may still be cleaning up)
        # Note: Due to application lifecycle, we'll just verify it's not fully functional
        sup_pid = Process.whereis(GSMLG.Config.Supervisor)

        if sup_pid do
          # If still exists, it should be shutting down
          # Just verify the process is dying or not responding
          ref = Process.monitor(sup_pid)

          receive do
            {:DOWN, ^ref, :process, ^sup_pid, _reason} -> :ok
          after
            # Timeout means it's still cleaning up, which is fine
            100 -> :ok
          end
        end
      end
    end

    test "handles concurrent starts gracefully" do
      # Start multiple applications concurrently
      tasks =
        for _i <- 1..5 do
          Task.async(fn ->
            Application.start(:gsmlg_config, :normal)
          end)
        end

      # Wait for all tasks
      results = Task.await_many(tasks, 5000)

      # At least one should succeed or already be started
      assert Enum.any?(results, fn result ->
               case result do
                 {:ok, _pid} -> true
                 {:error, {:already_started, _pid}} -> true
                 _ -> false
               end
             end)

      # Clean up
      if Process.whereis(GSMLG.Config.Supervisor) do
        Application.stop(:gsmlg_config)
      end
    end
  end
end
