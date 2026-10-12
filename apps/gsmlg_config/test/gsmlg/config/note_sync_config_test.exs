defmodule GSMLG.Config.NoteSyncConfigTest do
  use ExUnit.Case, async: false
  alias GSMLG.Config.{Schema, Setup}

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
    original = Application.get_env(:gsmlg_gao_note, :note_sync)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, original)
    end)

    config = %{enabled: true, trusted_proxy_ips: ["127.0.0.1"], max_blob_bytes: 2048}
    Setup.setup(%{note_sync: config})
    assert Application.get_env(:gsmlg_gao_note, :note_sync) == config
  end
end
