defmodule GSMLG.Commander.RunTest do
  use ExUnit.Case, async: false

  setup do
    original_config = Application.get_env(:gsmlg_commander, GSMLG.Commander)

    Application.put_env(:gsmlg_commander, GSMLG.Commander,
      start: false,
      name: "commander",
      platform_url: "ws://localhost:4111/commander-socket/websocket",
      platform_key: "dev-key"
    )

    on_exit(fn ->
      if original_config do
        Application.put_env(:gsmlg_commander, GSMLG.Commander, original_config)
      else
        Application.delete_env(:gsmlg_commander, GSMLG.Commander)
      end
    end)

    :ok
  end

  test "prepare_commander_run/1 enables agent auto-connect in dev" do
    assert :ok = GSMLG.Umbrella.MixProject.prepare_commander_run(:dev)

    commander_config = Application.get_env(:gsmlg_commander, GSMLG.Commander)
    assert commander_config[:start] == true
    assert commander_config[:server] == false
    assert commander_config[:name] == "commander"
    assert commander_config[:platform_url] == "ws://localhost:4111/commander-socket/websocket"
    assert commander_config[:platform_key] == "dev-key"
  end

  test "prepare_commander_run/1 leaves non-dev config unchanged" do
    assert :ok = GSMLG.Umbrella.MixProject.prepare_commander_run(:prod)

    commander_config = Application.get_env(:gsmlg_commander, GSMLG.Commander)
    assert commander_config[:start] == false
    assert commander_config[:server] == nil
    assert commander_config[:name] == "commander"
    assert commander_config[:platform_url] == "ws://localhost:4111/commander-socket/websocket"
    assert commander_config[:platform_key] == "dev-key"
  end
end
