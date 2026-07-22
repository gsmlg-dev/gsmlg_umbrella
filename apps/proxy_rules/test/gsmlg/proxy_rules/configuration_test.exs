defmodule GSMLG.ProxyRules.ConfigurationTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.Configuration

  @settings %{
    source_url: "https://example.test/list",
    remote_refresh_interval: 60_000,
    remote_connect_timeout: 500,
    remote_receive_timeout: 1_000,
    remote_max_body_size: 4_096,
    retry_min_interval: 100,
    retry_max_interval: 1_000,
    retry_jitter: false,
    local_proxy_list_path: "/tmp/proxy.txt",
    local_direct_list_path: "/tmp/direct.txt",
    local_watch_debounce: 25,
    local_reconciliation_interval: 250,
    state_directory: "/tmp/state",
    cache_control: "public, max-age=60",
    unsupported_rule_sample_limit: 0
  }

  @configuration %Configuration{
    source_url: "https://example.test/list",
    remote_refresh_interval: 60_000,
    remote_connect_timeout: 500,
    remote_receive_timeout: 1_000,
    remote_max_body_size: 4_096,
    retry_min_interval: 100,
    retry_max_interval: 1_000,
    retry_jitter: false,
    local_proxy_list_path: "/tmp/proxy.txt",
    local_direct_list_path: "/tmp/direct.txt",
    local_watch_debounce: 25,
    local_reconciliation_interval: 250,
    state_directory: "/tmp/state",
    cache_control: "public, max-age=60",
    unsupported_rule_sample_limit: 0
  }

  test "builds immutable settings including zero diagnostic samples" do
    settings = Map.put(@settings, :ignored_setting, :ignored)

    assert {:ok, config} = Configuration.new(settings)
    assert config == @configuration
  end

  test "loads immutable settings from the application environment" do
    previous_settings = Application.fetch_env(:proxy_rules, :settings)

    on_exit(fn ->
      case previous_settings do
        {:ok, settings} -> Application.put_env(:proxy_rules, :settings, settings)
        :error -> Application.delete_env(:proxy_rules, :settings)
      end
    end)

    Application.put_env(:proxy_rules, :settings, @settings)

    assert {:ok, config} = Configuration.load()
    assert config == @configuration
  end

  test "rejects a map missing validated settings" do
    assert {:error, {:missing_setting, :source_url}} = Configuration.new(%{})
  end

  test "accepts the persistence ceiling for remote bodies" do
    ceiling = 64 * 1024 * 1024

    assert Configuration.max_remote_body_size() == ceiling

    assert {:ok, %Configuration{remote_max_body_size: ^ceiling}} =
             Configuration.new(%{@settings | remote_max_body_size: ceiling})
  end

  test "rejects a remote body limit above the persistence ceiling" do
    above_ceiling = Configuration.max_remote_body_size() + 1

    assert {:error, {:invalid_setting, :remote_max_body_size}} =
             Configuration.new(%{@settings | remote_max_body_size: above_ceiling})
  end

  test "declares diagnostic sample limit as a non-negative integer" do
    assert {:ok, types} = Code.Typespec.fetch_types(Configuration)
    assert {:type, {:t, type, []}} = List.keyfind(types, :type, 0)
    assert {:type, _, :map, fields} = type

    assert {:type, _, :map_field_exact,
            [{:atom, _, :unsupported_rule_sample_limit}, declared_type]} =
             Enum.find(fields, fn
               {:type, _, :map_field_exact, [{:atom, _, :unsupported_rule_sample_limit}, _type]} ->
                 true

               _field ->
                 false
             end)

    assert {:type, _, :non_neg_integer, []} = declared_type
  end

  test "declares the remote body limit as bounded by the persistence ceiling" do
    assert {:ok, types} = Code.Typespec.fetch_types(Configuration)
    assert {:type, {:t, type, []}} = List.keyfind(types, :type, 0)
    assert {:type, _, :map, fields} = type

    assert {:type, _, :map_field_exact, [{:atom, _, :remote_max_body_size}, declared_type]} =
             Enum.find(fields, fn
               {:type, _, :map_field_exact, [{:atom, _, :remote_max_body_size}, _type]} ->
                 true

               _field ->
                 false
             end)

    assert {:type, _, :range, [{:integer, _, 1}, {:integer, _, 67_108_864}]} = declared_type
  end
end
