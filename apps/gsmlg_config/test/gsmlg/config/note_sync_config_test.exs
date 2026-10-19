defmodule GSMLG.Config.NoteSyncConfigTest do
  use ExUnit.Case, async: false
  alias GSMLG.Config.{Schema, Setup}

  setup do
    original = Application.fetch_env(:gsmlg_gao_note, :note_sync)

    on_exit(fn ->
      case original do
        {:ok, value} -> Application.put_env(:gsmlg_gao_note, :note_sync, value)
        :error -> Application.delete_env(:gsmlg_gao_note, :note_sync)
      end
    end)

    :ok
  end

  test "sync configuration defaults to only the aggregate byte cap" do
    assert {:ok, %{max_blob_bytes: 536_870_912} = settings} =
             Schema.validate_section(:note_sync, %{})

    assert map_size(settings) == 1
  end

  test "sync byte cap must be a positive integer no greater than 512 MiB" do
    for value <- [0, -1, 536_870_913, "1024", nil] do
      assert {:error, _} = Schema.validate_section(:note_sync, %{max_blob_bytes: value})
    end

    for value <- [1, 1024, 536_870_912] do
      assert {:ok, %{max_blob_bytes: ^value}} =
               Schema.validate_section(:note_sync, %{max_blob_bytes: value})
    end
  end

  test "legacy transport settings are ignored so existing TOML remains loadable" do
    for enabled <- [false, true] do
      assert {:ok, %{max_blob_bytes: 1024} = settings} =
               Schema.validate_section(:note_sync, %{
                 enabled: enabled,
                 ssh_enabled: enabled,
                 ssh_port: 4114,
                 trusted_proxy_ips: [],
                 max_blob_bytes: 1024
               })

      assert map_size(settings) == 1
    end
  end

  test "unrelated unknown options still fail validation" do
    assert {:error, _} = Schema.validate_section(:note_sync, %{ssh_bind: "0.0.0.0"})
  end

  test "validated sync byte cap reaches the runtime configuration" do
    assert {:ok, settings} = Schema.validate_section(:note_sync, %{max_blob_bytes: 2048})
    Setup.setup(%{note_sync: settings})
    assert Application.get_env(:gsmlg_gao_note, :note_sync) == %{max_blob_bytes: 2048}
  end

  test "setup does not retain legacy transport settings in the runtime configuration" do
    Setup.setup(%{
      note_sync: %{
        enabled: false,
        ssh_enabled: true,
        ssh_port: 4114,
        trusted_proxy_ips: ["127.0.0.1"],
        max_blob_bytes: 4096
      }
    })

    assert Application.get_env(:gsmlg_gao_note, :note_sync) == %{max_blob_bytes: 4096}
  end
end
