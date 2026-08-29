defmodule GSMLG.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias GSMLG.Config.Schema

  @expected %{
    source_url: "https://raw.githubusercontent.com/gfwlist/gfwlist/master/gfwlist.txt",
    remote_refresh_interval: 86_400_000,
    remote_connect_timeout: 5_000,
    remote_receive_timeout: 30_000,
    remote_max_body_size: 10_000_000,
    retry_min_interval: 5_000,
    retry_max_interval: 300_000,
    retry_jitter: true,
    local_proxy_list_path: "/etc/gsmlg/proxy-rules/proxy-list.txt",
    local_direct_list_path: "/etc/gsmlg/proxy-rules/direct-list.txt",
    local_watch_debounce: 500,
    local_reconciliation_interval: 60_000,
    state_directory: "/var/lib/gsmlg/proxy-rules",
    cache_control: "public, max-age=3600",
    unsupported_rule_sample_limit: 20
  }

  test "validates proxy-rules defaults" do
    assert {:ok, %{proxy_rules: settings}} = Schema.validate(%{proxy_rules: %{}})
    assert settings == @expected
  end

  test "rejects a zero remote refresh interval" do
    assert {:error, reason} =
             Schema.validate(%{proxy_rules: %{remote_refresh_interval: 0}})

    assert reason =~ "proxy_rules"
    assert reason =~ "positive integer"
  end

  test "rejects proxy-rules diagnostic limits above the persistence ceiling" do
    assert {:error, reason} =
             Schema.validate(%{proxy_rules: %{unsupported_rule_sample_limit: 1_001}})

    assert reason ==
             "proxy_rules: invalid unsupported_rule_sample_limit: expected an integer from 0 to 1000"
  end

  test "rejects a proxy-rules retry maximum below its minimum" do
    assert {:error, reason} =
             Schema.validate(%{
               proxy_rules: %{retry_min_interval: 10_000, retry_max_interval: 5_000}
             })

    assert reason ==
             "proxy_rules: invalid retry interval range: retry_max_interval must be greater than or equal to retry_min_interval"
  end

  test "defaults admin certificate auth to disabled" do
    assert {:ok, %{admin_web: settings}} =
             Schema.validate(%{admin_web: %{url: "https://admin.example.test"}})

    assert settings.client_certificate_auth == false
  end

  test "accepts enabled admin certificate auth" do
    assert {:ok, %{admin_web: settings}} =
             Schema.validate(%{
               admin_web: %{url: "https://admin.example.test", client_certificate_auth: true}
             })

    assert settings.client_certificate_auth == true
  end

  test "rejects string admin certificate auth" do
    assert {:error, reason} =
             Schema.validate(%{
               admin_web: %{url: "https://admin.example.test", client_certificate_auth: "true"}
             })

    assert reason =~ "admin_web"
    assert reason =~ "boolean"
  end

  test "checked-in TOMLs gate admin certificate auth to production" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for {filename, expected} <- [
          {"gsmlg.toml", false},
          {"gsmlg.dev.toml", false},
          {"gsmlg.test.toml", false},
          {"gsmlg.prod.toml", true}
        ] do
      assert {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
      assert config.admin_web.client_certificate_auth == expected
    end
  end

  test "active TOML files define the proxy-rules defaults" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for filename <- ~w(gsmlg.toml gsmlg.test.toml gsmlg.prod.toml) do
      assert {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
      assert config.proxy_rules == @expected
    end
  end

  test "development proxy-rules paths are writable project state provisioned by devenv" do
    config_dir = Path.expand("../../../priv", __DIR__)
    umbrella_root = Path.expand("../../../../..", __DIR__)

    assert {:ok, config} =
             Toml.decode_file(Path.join(config_dir, "gsmlg.dev.toml"), keys: :atoms)

    assert config.proxy_rules == %{
             @expected
             | local_proxy_list_path: ".devenv/state/proxy-rules/sources/proxy/proxy-list.txt",
               local_direct_list_path: ".devenv/state/proxy-rules/sources/direct/direct-list.txt",
               state_directory: ".devenv/state/proxy-rules"
           }

    devenv = File.read!(Path.join(umbrella_root, "devenv.nix"))

    assert devenv =~ "proxy_rules_state=.devenv/state/proxy-rules"
    assert devenv =~ ~s(mkdir -p -- "$proxy_rules_state/sources/proxy")
    assert devenv =~ ~s("$proxy_rules_state/sources/direct")
  end
end
