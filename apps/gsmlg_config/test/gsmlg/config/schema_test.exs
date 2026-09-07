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

  test "commander mTLS defaults disabled and validates a fail-closed enabled configuration" do
    assert {:ok, %{commander: commander}} = Schema.validate(%{commander: %{}})
    assert commander.tls.enabled == false

    assert {:error, missing_reason} =
             Schema.validate(%{
               commander: %{
                 start: true,
                 platform_url: "wss://commander.example.test/socket",
                 tls: %{enabled: true}
               }
             })

    assert missing_reason =~ "client_cert_file"
    assert missing_reason =~ "client_key_file"

    assert {:error, scheme_reason} =
             Schema.validate(%{
               commander: %{
                 start: true,
                 platform_url: "ws://commander.example.test/socket",
                 tls: %{
                   enabled: true,
                   client_cert_file: "/run/secrets/client.pem",
                   client_key_file: "/run/secrets/client-key.pem"
                 }
               }
             })

    assert scheme_reason =~ "wss://"
  end

  test "Commander RPC admission has a finite positive default" do
    assert {:ok, %{commander: %{max_in_flight_rpcs: 2}}} =
             Schema.validate(%{commander: %{}})

    assert {:error, reason} =
             Schema.validate(%{commander: %{max_in_flight_rpcs: 0}})

    assert reason =~ "max_in_flight_rpcs"
    assert reason =~ "positive integer"
  end

  test "commander mTLS accepts a secure websocket derived from umbrella_server_url" do
    assert {:ok, %{commander: commander}} =
             Schema.validate(%{
               commander: %{
                 start: true,
                 name: "node-a",
                 credential_id: "node-a-credential",
                 platform_key: "runtime-secret",
                 umbrella_server_url: "https://commander.example.test",
                 tls: %{
                   enabled: true,
                   client_cert_file: "/run/secrets/client.pem",
                   client_key_file: "/run/secrets/client-key.pem"
                 }
               }
             })

    assert commander.tls.enabled
  end

  test "Commander agent and server authentication configuration fails closed" do
    valid_agent = %{
      start: true,
      name: "node-a",
      credential_id: "node-a-credential",
      platform_url: "wss://commander.example.test/commander-socket/websocket",
      platform_key: "runtime-secret"
    }

    assert {:ok, _config} = Schema.validate(%{commander: valid_agent})

    for field <- [:name, :credential_id, :platform_url, :platform_key] do
      assert {:error, reason} = Schema.validate(%{commander: Map.put(valid_agent, field, "")})
      assert reason =~ Atom.to_string(field)
    end

    for url <- ["https://example.test/socket", "ws:///socket", "not a url"] do
      assert {:error, reason} =
               Schema.validate(%{commander: Map.put(valid_agent, :platform_url, url)})

      assert reason =~ "platform_url"
    end

    assert {:error, credentials_reason} =
             Schema.validate(%{
               commander: %{
                 server: true,
                 platform_credentials: %{},
                 platform_credentials_env: ""
               }
             })

    assert credentials_reason =~ "platform_credentials"

    assert {:error, nonce_reason} =
             Schema.validate(%{
               commander:
                 Map.merge(valid_agent, %{
                   auth_timestamp_window_seconds: 60,
                   auth_nonce_ttl_ms: 119_999
                 })
             })

    assert nonce_reason =~ "auth_nonce_ttl_ms"
  end

  test "production Commander defaults do not enable an agent with a placeholder secret" do
    path = Path.expand("../../../priv/gsmlg.prod.toml", __DIR__)
    assert {:ok, config} = Toml.decode_file(path, keys: :atoms)
    refute config.commander.start
    refute Map.get(config.commander, :platform_key) == "CHANGE_ME_IN_PRODUCTION"
  end

  test "checked-in TOMLs explicitly disable Commander mTLS by default" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for filename <- ~w(gsmlg.toml gsmlg.dev.toml gsmlg.test.toml gsmlg.prod.toml) do
      assert {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
      assert config.commander.tls.enabled == false
      assert config.commander.max_in_flight_rpcs == 2
    end
  end

  test "browser agent defaults are disabled and contain only a runtime token reference" do
    assert {:ok, %{browser_agent: settings}} = Schema.validate(%{browser_agent: %{}})

    assert settings.enabled == false
    assert settings.backend == "cloakbrowser"
    assert settings.manager_url == "http://127.0.0.1:8080"
    assert settings.manager_token_env == "CLOAKBROWSER_MANAGER_TOKEN"
    refute Map.has_key?(settings, :manager_token)
    assert settings.max_response_bytes == 1_048_576
    assert settings.journal_terminal_max_records == 10_000
    assert settings.journal_terminal_max_age_ms == 2_592_000_000
    assert settings.journal_terminal_max_bytes == 67_108_864
    assert settings.journal_recovery_scan_max_records == 10_000
    assert settings.security.allow_css_locator == false
  end

  test "enabled browser agent rejects non-loopback Manager and blank secret references" do
    assert {:error, url_reason} =
             Schema.validate(%{
               browser_agent: %{
                 enabled: true,
                 manager_url: "http://manager.example.test:8080",
                 manager_token_env: "CLOAKBROWSER_MANAGER_TOKEN"
               }
             })

    assert url_reason =~ "loopback"

    assert {:error, token_reason} =
             Schema.validate(%{
               browser_agent: %{
                 enabled: true,
                 manager_url: "http://127.0.0.1:8080",
                 manager_token_env: ""
               }
             })

    assert token_reason =~ "manager_token_env"
  end

  test "checked-in TOMLs keep browser agent disabled and never contain a Manager token" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for filename <- ~w(gsmlg.toml gsmlg.dev.toml gsmlg.test.toml gsmlg.prod.toml) do
      assert {:ok, config} = Toml.decode_file(Path.join(config_dir, filename), keys: :atoms)
      assert config.browser_agent.enabled == false
      assert config.browser_agent.manager_token_env == "CLOAKBROWSER_MANAGER_TOKEN"
      assert config.browser_agent.journal_terminal_max_records == 10_000
      assert config.browser_agent.journal_terminal_max_age_ms == 2_592_000_000
      assert config.browser_agent.journal_terminal_max_bytes == 67_108_864
      assert config.browser_agent.journal_recovery_scan_max_records == 10_000
      assert config.browser_agent.security.allow_css_locator == false
      refute Map.has_key?(config.browser_agent, :manager_token)
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
