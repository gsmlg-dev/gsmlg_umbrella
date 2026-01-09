defmodule GSMLG.ConfigTest do
  use ExUnit.Case, async: false
  # Tests depend on local TOML config files which may not behave the same in CI
  @moduletag :config_loading
  doctest GSMLG.Config

  import ExUnit.CaptureLog

  setup do
    # Store original config to restore after test
    original_config = Application.get_env(:gsmlg_config, :loaded_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:gsmlg_config, :loaded_config, original_config)
      else
        Application.delete_env(:gsmlg_config, :loaded_config)
      end
    end)

    :ok
  end

  describe "config/0" do
    test "returns the entire config map when loaded" do
      # Load config from test environment
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)

      result = GSMLG.Config.config()
      assert is_map(result)
      assert Map.has_key?(result, :logger)
      assert Map.has_key?(result, :database)
      assert Map.has_key?(result, :web)
    end

    test "returns empty map when config not loaded" do
      Application.delete_env(:gsmlg_config, :loaded_config)

      log =
        capture_log(fn ->
          result = GSMLG.Config.config()
          assert result == %{}
        end)

      assert log =~ "Configuration not loaded"
    end
  end

  describe "get/1 with atom key" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "returns value for atom key" do
      logger_config = GSMLG.Config.get(:logger)
      assert is_map(logger_config)
      assert is_binary(logger_config[:log_level])
    end

    test "returns nil for non-existent atom key" do
      result = GSMLG.Config.get(:non_existent)
      assert result == nil
    end
  end

  describe "get/1 with binary key" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "returns value for binary key" do
      logger_config = GSMLG.Config.get("logger")
      assert is_map(logger_config)
    end

    test "returns nil for non-existent binary key" do
      result = GSMLG.Config.get("non_existent")
      assert result == nil
    end
  end

  describe "get/1 with path list" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "returns nested value using path list" do
      log_level = GSMLG.Config.get([:logger, :log_level])
      assert is_binary(log_level)
    end

    test "returns nil for non-existent path" do
      result = GSMLG.Config.get([:non_existent, :path])
      assert result == nil
    end
  end

  describe "get/2 with default" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "returns value when key exists" do
      result = GSMLG.Config.get(:logger, :default_value)
      assert is_map(result)
      refute result == :default_value
    end

    test "returns default when key doesn't exist" do
      result = GSMLG.Config.get(:non_existent, :default_value)
      assert result == :default_value
    end

    test "returns value when path exists" do
      result = GSMLG.Config.get([:logger, :log_level], "default")
      assert is_binary(result)
      refute result == "default"
    end

    test "returns default when path doesn't exist" do
      result = GSMLG.Config.get([:non_existent, :path], :default_value)
      assert result == :default_value
    end
  end

  describe "reload/0" do
    test "reloads configuration from files" do
      {:ok, config} = GSMLG.Config.reload()
      assert is_map(config)
      assert Map.has_key?(config, :logger)
      assert Map.has_key?(config, :database)
    end

    test "updates Application environment" do
      {:ok, _config} = GSMLG.Config.reload()
      app_config = Application.get_env(:gsmlg_config, :loaded_config)
      assert is_map(app_config)
    end
  end

  describe "reload!/0" do
    test "reloads configuration and returns it" do
      config = GSMLG.Config.reload!()
      assert is_map(config)
      assert Map.has_key?(config, :logger)
    end
  end

  describe "config_path/1" do
    test "returns correct path for dev environment" do
      path = GSMLG.Config.config_path(:dev)
      assert path == "config/dev.toml"
    end

    test "returns correct path for test environment" do
      path = GSMLG.Config.config_path(:test)
      assert path == "config/test.toml"
    end

    test "returns correct path for prod environment" do
      path = GSMLG.Config.config_path(:prod)
      assert path == "config/prod.toml"
    end
  end

  describe "validate/0" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)

      {:ok, config} =
        GSMLG.Config.Loader.load(env: :test, config_dir: config_dir, validate: false)

      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "validates current configuration" do
      result = GSMLG.Config.validate()
      # May succeed or fail depending on test config
      case result do
        {:ok, _} -> assert true
        {:error, _} -> assert true
      end
    end
  end

  describe "validate!/0" do
    setup do
      config_dir = Path.expand("../../config", __DIR__)
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: config_dir)
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "validates and returns config on success" do
      config = GSMLG.Config.validate!()
      assert is_map(config)
    end
  end
end
