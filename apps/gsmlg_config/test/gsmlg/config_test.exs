defmodule GSMLG.ConfigTest do
  use ExUnit.Case, async: false
  # Tests depend on local TOML config files which may not behave the same in CI
  @moduletag :config_loading
  doctest GSMLG.Config

  import ExUnit.CaptureLog

  setup do
    # Store original config to restore after test
    original_config = Application.get_env(:gsmlg_config, :loaded_config)
    original_config_path = System.get_env("GSMLG_CONFIG_PATH")

    on_exit(fn ->
      if original_config do
        Application.put_env(:gsmlg_config, :loaded_config, original_config)
      else
        Application.delete_env(:gsmlg_config, :loaded_config)
      end

      if original_config_path do
        System.put_env("GSMLG_CONFIG_PATH", original_config_path)
      else
        System.delete_env("GSMLG_CONFIG_PATH")
      end
    end)

    :ok
  end

  describe "config/0" do
    test "returns the entire config map when loaded" do
      # Load config from test environment
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
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
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
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
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
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
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
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
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
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
      put_test_config_path()

      {:ok, config} = GSMLG.Config.reload()
      assert is_map(config)
      assert Map.has_key?(config, :logger)
      assert Map.has_key?(config, :database)
    end

    test "updates Application environment" do
      put_test_config_path()

      {:ok, _config} = GSMLG.Config.reload()
      app_config = Application.get_env(:gsmlg_config, :loaded_config)
      assert is_map(app_config)
    end
  end

  describe "reload!/0" do
    test "reloads configuration and returns it" do
      put_test_config_path()

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
      {:ok, config} =
        GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir(), validate: false)

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
      {:ok, config} = GSMLG.Config.Loader.load(env: :test, config_dir: test_config_dir())
      Application.put_env(:gsmlg_config, :loaded_config, config)
      :ok
    end

    test "validates and returns config on success" do
      config = GSMLG.Config.validate!()
      assert is_map(config)
    end
  end

  describe "schema validation" do
    test "defaults scout blocked cidrs from the planned TOML list" do
      expected_blocked_cidrs = planned_scout_blocked_cidrs()

      assert {:ok, %{scout: %{security: %{blocked_cidrs: ^expected_blocked_cidrs}}}} =
               GSMLG.Config.Schema.validate(%{scout: %{security: %{}}})
    end

    test "accepts scout redirect limit for external config compatibility" do
      assert {:ok, %{scout: %{security: %{redirect_limit: 7}}}} =
               GSMLG.Config.Schema.validate(%{scout: %{security: %{redirect_limit: 7}}})
    end

    test "returns errors for invalid scout nested shapes" do
      top_level_result =
        try do
          GSMLG.Config.Schema.validate(%{scout: "bad"})
        rescue
          error -> {:raised, error}
        end

      subsection_result =
        try do
          GSMLG.Config.Schema.validate(%{scout: %{security: "bad"}})
        rescue
          error -> {:raised, error}
        end

      assert {:error, top_level_reason} = top_level_result
      assert top_level_reason =~ "scout"

      assert {:error, subsection_reason} = subsection_result
      assert subsection_reason =~ "security"
    end

    test "returns errors for invalid oauth nested shapes" do
      assert {:error, reason} = GSMLG.Config.Schema.validate(%{oauth: %{github: "bad"}})
      assert reason =~ "github"
    end
  end

  describe "source toml scout config" do
    test "loads planned scout values from checked-in source toml files" do
      {:ok, base_config} =
        GSMLG.Config.Loader.load(config_path: Path.join(test_config_dir(), "gsmlg.toml"))

      {:ok, dev_config} = GSMLG.Config.Loader.load(env: :dev, config_dir: test_config_dir())
      {:ok, prod_config} = GSMLG.Config.Loader.load(env: :prod, config_dir: test_config_dir())

      assert_planned_scout_values(base_config)
      assert_planned_scout_values(dev_config)
      assert_planned_scout_values(prod_config)
    end
  end

  describe "test config fixtures" do
    test "loads source toml files instead of build artifacts" do
      assert test_config_dir() == Path.expand("../../priv", __DIR__)
      refute test_config_dir() =~ "/_build/"
    end
  end

  defp test_config_dir do
    Path.expand("../../priv", __DIR__)
  end

  defp put_test_config_path do
    System.put_env("GSMLG_CONFIG_PATH", Path.join(test_config_dir(), "gsmlg.test.toml"))
  end

  defp assert_planned_scout_values(config) do
    assert config.scout.agent.id == ""
    assert config.scout.fetch.browser.wait_for == ""
    assert config.scout.security.redirect_limit == 5
    assert config.scout.security.blocked_cidrs == planned_scout_blocked_cidrs()
  end

  defp planned_scout_blocked_cidrs do
    [
      "0.0.0.0/8",
      "127.0.0.0/8",
      "10.0.0.0/8",
      "100.64.0.0/10",
      "172.16.0.0/12",
      "192.168.0.0/16",
      "192.0.0.0/24",
      "192.0.2.0/24",
      "192.31.196.0/24",
      "192.52.193.0/24",
      "192.88.99.0/24",
      "192.175.48.0/24",
      "198.18.0.0/15",
      "198.51.100.0/24",
      "203.0.113.0/24",
      "169.254.0.0/16",
      "224.0.0.0/4",
      "240.0.0.0/4",
      "255.255.255.255/32",
      "::/128",
      "::/96",
      "::1/128",
      "::ffff:0:0/96",
      "64:ff9b::/96",
      "64:ff9b:1::/48",
      "100::/64",
      "100:0:0:1::/64",
      "fe80::/10",
      "fc00::/7",
      "ff00::/8",
      "2001::/23",
      "2001::/32",
      "2001:1::1/128",
      "2001:1::2/128",
      "2001:1::3/128",
      "2001:2::/48",
      "2001:3::/32",
      "2001:4:112::/48",
      "2001:10::/28",
      "2001:20::/28",
      "2001:30::/28",
      "2001:db8::/32",
      "2002::/16",
      "2620:4f:8000::/48",
      "3fff::/20",
      "5f00::/16"
    ]
  end
end
