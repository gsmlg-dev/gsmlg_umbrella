defmodule GSMLG.Config.NoteSyncConfigTest do
  use ExUnit.Case, async: false
  alias GSMLG.Config.{Schema, Setup}

  setup do
    for {app, key} <- [
          {:gsmlg_gao_note, :note_sync},
          {:gsmlg_admin_web, GSMLG.AdminWeb.NoteSyncSSHEndpoint}
        ] do
      original = Application.fetch_env(app, key)

      on_exit(fn ->
        case original do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end)
    end

    :ok
  end

  test "sync ingress defaults disabled and validates exact proxy addresses and byte cap" do
    assert {:ok, %{enabled: false, trusted_proxy_ips: [], max_blob_bytes: 536_870_912}} =
             Schema.validate_section(:note_sync, %{})

    for config <- [
          %{enabled: true},
          %{trusted_proxy_ips: ["127.0.0.0/8"]},
          %{trusted_proxy_ips: ["localhost"]},
          %{max_blob_bytes: 536_870_913},
          %{max_blob_bytes: 0}
        ] do
      assert {:error, _} = Schema.validate_section(:note_sync, config)
    end

    assert {:ok, _} =
             Schema.validate_section(:note_sync, %{
               enabled: true,
               trusted_proxy_ips: ["127.0.0.1", "::1"],
               max_blob_bytes: 1024
             })
  end

  test "validated sync settings reach the socket without enabling browser identity trust" do
    config = %{enabled: true, trusted_proxy_ips: ["127.0.0.1"], max_blob_bytes: 2048}
    Setup.setup(%{note_sync: config})
    assert Application.get_env(:gsmlg_gao_note, :note_sync) == config
  end

  test "SSH ingress defaults disabled and enables independently of the mTLS ingress" do
    assert {:ok, %{enabled: false, ssh_enabled: false, ssh_port: 4114}} =
             Schema.validate_section(:note_sync, %{})

    assert {:ok, %{enabled: false, ssh_enabled: true, trusted_proxy_ips: []}} =
             Schema.validate_section(:note_sync, %{ssh_enabled: true})

    assert {:error, _} =
             Schema.validate_section(:note_sync, %{enabled: true, ssh_enabled: true})
  end

  test "SSH ingress accepts only a boolean enablement and a valid TCP port" do
    for config <- [
          %{ssh_enabled: "true"},
          %{ssh_port: 0},
          %{ssh_port: -1},
          %{ssh_port: 65_536},
          %{ssh_port: "4114"},
          %{ssh_bind: "0.0.0.0"}
        ] do
      assert {:error, _} = Schema.validate_section(:note_sync, config)
    end

    for port <- [1, 4114, 65_535] do
      assert {:ok, %{ssh_port: ^port}} =
               Schema.validate_section(:note_sync, %{ssh_port: port})
    end
  end

  test "SSH setup enables only the loopback listener and keeps endpoint transport settings" do
    endpoint = GSMLG.AdminWeb.NoteSyncSSHEndpoint

    Application.put_env(:gsmlg_admin_web, endpoint,
      adapter: Bandit.PhoenixAdapter,
      pubsub_server: GSMLG.PubSub
    )

    assert {:ok, settings} =
             Schema.validate_section(:note_sync, %{ssh_enabled: true, ssh_port: 4314})

    Setup.setup(%{note_sync: settings})
    config = Application.fetch_env!(:gsmlg_admin_web, endpoint)

    assert config[:server] == true
    assert config[:http] == [ip: {127, 0, 0, 1}, port: 4314]
    assert config[:url] == [scheme: "http", host: "localhost", port: 4314]
    assert config[:adapter] == Bandit.PhoenixAdapter
    assert config[:pubsub_server] == GSMLG.PubSub
    assert Application.fetch_env!(:gsmlg_gao_note, :note_sync) == settings
  end

  test "legacy and absent sync settings disable a previously configured SSH listener" do
    endpoint = GSMLG.AdminWeb.NoteSyncSSHEndpoint

    for config <- [%{note_sync: %{enabled: false}}, %{}] do
      Application.put_env(:gsmlg_admin_web, endpoint,
        server: true,
        http: [ip: {0, 0, 0, 0}, port: 4314]
      )

      Setup.setup(config)
      settings = Application.fetch_env!(:gsmlg_admin_web, endpoint)

      assert settings[:server] == false
      assert settings[:http] == [ip: {127, 0, 0, 1}, port: 4114]
      assert settings[:url] == [scheme: "http", host: "localhost", port: 4114]
    end
  end
end
