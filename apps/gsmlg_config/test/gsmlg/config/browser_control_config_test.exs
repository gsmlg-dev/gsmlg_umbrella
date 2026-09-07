defmodule GSMLG.Config.BrowserControlConfigTest do
  use ExUnit.Case, async: true

  alias GSMLG.Config.Schema

  @toml_files ~w(gsmlg.toml gsmlg.dev.toml gsmlg.test.toml gsmlg.prod.toml)

  test "central Browser control has bounded disabled defaults" do
    assert {:ok, %{browser: browser}} = Schema.validate(%{browser: %{}})

    assert browser.enabled == false
    assert browser.default_node == nil
    assert browser.inline_artifact_max_bytes == 131_072
    assert browser.event_retention_days == 30
    assert browser.upload_ttl_seconds == 300
    assert browser.jobs.dispatch_timeout_ms == 30_000
    assert browser.jobs.reconcile_interval_ms == 30_000
    assert browser.jobs.default_deadline_ms == 7_200_000
    assert browser.jobs.max_attempts == 3
    assert browser.security.allowed_schemes == ["https"]
    assert browser.security.allow_css_locator == false
    assert browser.security.allow_downloads == true
    assert browser.security.max_observation_bytes == 1_048_576
    assert browser.security.max_artifact_bytes == 104_857_600
  end

  test "enabled central Browser control requires a bounded HTTPS upload target" do
    assert {:ok, %{browser: browser}} =
             Schema.validate(%{
               browser: %{
                 enabled: true,
                 upload_base_url: "https://admin.example.test/browser-artifact-uploads"
               }
             })

    assert browser.upload_base_url ==
             "https://admin.example.test/browser-artifact-uploads"

    for valid <- [
          "https://admin.example.test",
          "https://admin.example.test/",
          "https://admin.example.test/browser-artifact-uploads"
        ] do
      assert {:ok, %{browser: %{upload_base_url: ^valid}}} =
               Schema.validate(%{browser: %{enabled: true, upload_base_url: valid}})
    end

    for invalid <- [
          "",
          "http://admin.example.test/browser-artifact-uploads",
          "https://user:secret@admin.example.test/browser-artifact-uploads",
          "https://admin.example.test/browser-artifact-uploads?token=secret",
          "https://admin.example.test/browser-artifact-uploads#fragment",
          "https://admin.example.test/not-the-ingress",
          "https://admin.example.test/browser-artifact-uploads/"
        ] do
      assert {:error, reason} =
               Schema.validate(%{browser: %{enabled: true, upload_base_url: invalid}})

      assert reason =~ "upload_base_url"
    end
  end

  test "central Browser control rejects unsafe or contradictory limits" do
    base = %{
      enabled: true,
      upload_base_url: "https://admin.example.test/browser-artifact-uploads"
    }

    for {override, field} <- [
          {%{inline_artifact_max_bytes: 131_073}, "inline_artifact_max_bytes"},
          {%{upload_ttl_seconds: 901}, "upload_ttl_seconds"},
          {%{security: %{allowed_schemes: ["http", "https"]}}, "allowed_schemes"},
          {%{security: %{max_observation_bytes: 1_048_577}}, "max_observation_bytes"},
          {%{security: %{max_artifact_bytes: 0}}, "max_artifact_bytes"},
          {%{jobs: %{max_attempts: 0}}, "max_attempts"}
        ] do
      assert {:error, reason} = Schema.validate(%{browser: Map.merge(base, override)})
      assert reason =~ field
    end
  end

  test "enabled Browser Agent requires canonical HTTPS origins and bounded payloads" do
    base = %{
      enabled: true,
      manager_url: "http://127.0.0.1:8080",
      manager_token_env: "CLOAKBROWSER_MANAGER_TOKEN",
      state_dir: "/var/lib/gsmlg/browser-agent",
      security: %{
        allowed_origins: ["https://gemini.google.com"],
        allowed_upload_origins: ["https://admin.example.test"]
      }
    }

    assert {:ok, %{browser_agent: browser_agent}} =
             Schema.validate(%{browser_agent: base})

    assert browser_agent.max_observation_bytes == 1_048_576
    assert browser_agent.max_artifact_bytes == 104_857_600
    assert browser_agent.inline_artifact_max_bytes == 131_072

    for {override, field} <- [
          {%{security: %{allowed_origins: []}}, "allowed_origins"},
          {%{security: %{allowed_origins: ["http://gemini.google.com"]}}, "allowed_origins"},
          {%{security: %{allowed_origins: ["https://gemini.google.com/app"]}}, "allowed_origins"},
          {%{security: %{allowed_upload_origins: []}}, "allowed_upload_origins"},
          {%{security: %{allowed_upload_origins: ["http://admin.example.test"]}},
           "allowed_upload_origins"},
          {%{security: %{allowed_upload_origins: ["https://admin.example.test/upload"]}},
           "allowed_upload_origins"},
          {%{max_observation_bytes: 1_048_577}, "max_observation_bytes"},
          {%{max_artifact_bytes: 0}, "max_artifact_bytes"},
          {%{inline_artifact_max_bytes: 131_073}, "inline_artifact_max_bytes"}
        ] do
      security = Map.merge(base.security, Map.get(override, :security, %{}))

      assert {:error, reason} =
               Schema.validate(%{
                 browser_agent: base |> Map.merge(override) |> Map.put(:security, security)
               })

      assert reason =~ field
    end
  end

  test "enabled Browser Agent applies nested defaults before returning a stable security error" do
    assert {:error, reason} = Schema.validate(%{browser_agent: %{enabled: true}})
    assert reason =~ "allowed_origins"
  end

  test "checked-in TOML contains only Browser secret references and disabled defaults" do
    config_dir = Path.expand("../../../priv", __DIR__)

    for filename <- @toml_files do
      path = Path.join(config_dir, filename)
      source = File.read!(path)
      assert {:ok, config} = Toml.decode_file(path, keys: :atoms)

      assert config.browser.enabled == false
      assert config.browser.inline_artifact_max_bytes == 131_072
      assert config.browser_agent.enabled == false
      assert config.browser_agent.manager_token_env == "CLOAKBROWSER_MANAGER_TOKEN"
      assert config.browser_agent.security.allowed_upload_origins == []
      assert config.commander.platform_key_env == "GSMLG_COMMANDER_PLATFORM_KEY"

      assert config.commander.platform_credentials_env ==
               "GSMLG_COMMANDER_PLATFORM_CREDENTIALS_JSON"

      refute Regex.match?(~r/^\s*platform_key\s*=/m, source)
      refute Regex.match?(~r/^\s*manager_token\s*=/m, source)
      refute Regex.match?(~r/^\s*client_key\s*=/m, source)
      refute Regex.match?(~r/^\s*platform_credentials\s*=/m, source)
    end
  end

  test "Commander server accepts only a runtime credential-map reference when no map is supplied" do
    assert {:ok, %{commander: commander}} =
             Schema.validate(%{
               commander: %{
                 server: true,
                 platform_credentials_env: "GSMLG_COMMANDER_PLATFORM_CREDENTIALS_JSON"
               }
             })

    assert commander.platform_credentials == %{}

    assert {:error, reason} =
             Schema.validate(%{
               commander: %{server: true, platform_credentials_env: ""}
             })

    assert reason =~ "platform_credentials"
  end

  test "sanitized central and remote deployment fragments parse and validate" do
    examples = Path.expand("../../../../../docs/commander/examples", __DIR__)

    for filename <- ~w(central-browser.toml remote-browser-agent.toml) do
      assert {:ok, config} =
               Toml.decode_file(Path.join(examples, filename), keys: :atoms)

      assert {:ok, _validated} = Schema.validate(config)
    end
  end
end
