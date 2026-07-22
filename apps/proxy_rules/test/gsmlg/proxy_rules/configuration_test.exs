defmodule GSMLG.ProxyRules.ConfigurationTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.Configuration

  test "builds immutable settings from a validated map" do
    assert {:ok, config} =
             Configuration.new(%{
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
               unsupported_rule_sample_limit: 3
             })

    assert %Configuration{source_url: "https://example.test/list", retry_jitter: false} = config
  end

  test "rejects a map missing validated settings" do
    assert {:error, {:missing_setting, :source_url}} = Configuration.new(%{})
  end
end
