defmodule GSMLG.Config.BrowserControlSetupTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.Setup

  setup do
    previous_browser = Application.get_env(:gsmlg_browser, :settings)
    previous_oban = Application.get_env(:gsmlg, Oban)
    previous_commander = Application.get_env(:gsmlg_commander, GSMLG.Commander)

    on_exit(fn ->
      restore_env(:gsmlg_browser, :settings, previous_browser)
      restore_env(:gsmlg, Oban, previous_oban)
      restore_env(:gsmlg_commander, GSMLG.Commander, previous_commander)
    end)

    :ok
  end

  test "configures central Browser limits and its finite Oban queues" do
    config = %{
      enabled: true,
      default_node: "gemini-browser-01",
      inline_artifact_max_bytes: 131_072,
      event_retention_days: 30,
      upload_base_url: "https://admin.example.test/browser-artifact-uploads",
      upload_ttl_seconds: 300,
      jobs: %{
        dispatch_timeout_ms: 30_000,
        reconcile_interval_ms: 30_000,
        default_deadline_ms: 7_200_000,
        max_attempts: 3
      },
      security: %{
        allowed_schemes: ["https"],
        allow_css_locator: false,
        allow_downloads: true,
        max_observation_bytes: 1_048_576,
        max_artifact_bytes: 104_857_600
      }
    }

    Setup.setup_browser(config)

    assert Application.fetch_env!(:gsmlg_browser, :settings) == config
    assert Application.fetch_env!(:gsmlg_browser, :upload_base_url) == config.upload_base_url
    assert Application.fetch_env!(:gsmlg_browser, :default_deadline_ms) == 7_200_000
    assert Application.fetch_env!(:gsmlg_browser, :max_artifact_bytes) == 104_857_600

    queues = Application.fetch_env!(:gsmlg, Oban)[:queues]
    assert queues[:browser_dispatch] == 2
    assert queues[:browser_reconcile] == 1
    assert queues[:browser_retention] == 1
  end

  test "Commander resolves an enabled agent key from the named runtime environment variable" do
    variable = "GSMLG_TEST_COMMANDER_PLATFORM_KEY"
    previous = System.get_env(variable)
    System.put_env(variable, "runtime-only-secret")

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    Setup.setup_commander(%{
      start: true,
      server: false,
      name: "browser-node",
      credential_id: "browser-node-credential",
      platform_url: "wss://admin.example.test/commander-socket/websocket",
      platform_key_env: variable,
      platform_credentials: %{},
      features: ["pty"],
      auth_timestamp_window_seconds: 60,
      auth_nonce_ttl_ms: 120_000,
      max_in_flight_rpcs: 2,
      tls: %{enabled: false, reload_interval_ms: 60_000}
    })

    assert Application.fetch_env!(:gsmlg_commander, GSMLG.Commander)[:platform_key] ==
             "runtime-only-secret"
  end

  test "enabled Commander fails closed when its runtime key is unavailable" do
    variable = "GSMLG_TEST_MISSING_COMMANDER_PLATFORM_KEY"
    previous = System.get_env(variable)
    System.delete_env(variable)

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    assert_raise ArgumentError, ~r/runtime Commander credential/, fn ->
      Setup.setup_commander(%{
        start: true,
        server: false,
        name: "browser-node",
        credential_id: "browser-node-credential",
        platform_url: "wss://admin.example.test/commander-socket/websocket",
        platform_key_env: variable,
        platform_credentials: %{},
        features: ["pty"],
        auth_timestamp_window_seconds: 60,
        auth_nonce_ttl_ms: 120_000,
        max_in_flight_rpcs: 2,
        tls: %{enabled: false, reload_interval_ms: 60_000}
      })
    end
  end

  test "Commander server resolves and validates its runtime credential map" do
    variable = "GSMLG_TEST_COMMANDER_CREDENTIALS_JSON"
    previous = System.get_env(variable)

    System.put_env(
      variable,
      JSON.encode!(%{
        "browser-node-credential" => %{
          "key" => "server-side-runtime-secret",
          "commander_name" => "browser-node"
        }
      })
    )

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    Setup.setup_commander(%{
      start: false,
      server: true,
      name: "central",
      platform_credentials: %{},
      platform_credentials_env: variable,
      features: ["pty"],
      auth_timestamp_window_seconds: 60,
      auth_nonce_ttl_ms: 120_000,
      max_in_flight_rpcs: 2,
      tls: %{enabled: false, reload_interval_ms: 60_000}
    })

    assert %{
             "browser-node-credential" => %{
               "key" => "server-side-runtime-secret",
               "commander_name" => "browser-node"
             }
           } =
             Application.fetch_env!(:gsmlg_commander, GSMLG.Commander)[:platform_credentials]
  end

  test "enabled Commander server fails closed on missing or malformed credential JSON" do
    variable = "GSMLG_TEST_BAD_COMMANDER_CREDENTIALS_JSON"
    previous = System.get_env(variable)

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    config = %{
      start: false,
      server: true,
      name: "central",
      platform_credentials: %{},
      platform_credentials_env: variable,
      features: ["pty"],
      auth_timestamp_window_seconds: 60,
      auth_nonce_ttl_ms: 120_000,
      max_in_flight_rpcs: 2,
      tls: %{enabled: false, reload_interval_ms: 60_000}
    }

    for value <- [nil, "not-json", ~s({"node":{"key":"","commander_name":"node"}})] do
      if value, do: System.put_env(variable, value), else: System.delete_env(variable)

      assert_raise ArgumentError, ~r/runtime Commander credential map/, fn ->
        Setup.setup_commander(config)
      end
    end
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
