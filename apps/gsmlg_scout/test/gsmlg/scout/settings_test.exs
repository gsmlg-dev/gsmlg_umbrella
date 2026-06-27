defmodule GSMLG.Scout.SettingsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Settings

  setup do
    previous = Application.get_env(:gsmlg_scout, :settings)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:gsmlg_scout, :settings)
        value -> Application.put_env(:gsmlg_scout, :settings, value)
      end
    end)

    :ok
  end

  test "normalizes application settings with defaults" do
    Application.put_env(:gsmlg_scout, :settings, %{
      general: %{instance_name: "Test Scout", default_region: "test"},
      fetch: %{default_timeout_ms: 1_000, max_timeout_ms: 2_000, retry: %{max_attempts: 2}},
      agent: %{id: "test-agent-1"}
    })

    settings = Settings.get()

    assert settings["general"]["instance_name"] == "Test Scout"
    assert settings["general"]["default_region"] == "test"
    assert settings["fetch"]["default_timeout_ms"] == 1_000
    assert settings["fetch"]["max_timeout_ms"] == 2_000
    assert settings["fetch"]["retry"]["max_attempts"] == 2
    assert settings["agent"]["id"] == "test-agent-1"
    assert settings["rabbitmq"]["queues"]["jobs"] == "scout.fetch.jobs"
  end

  test "falls back to environment agent id when configured id is blank" do
    previous_env = System.get_env("SCOUT_AGENT_ID")

    on_exit(fn ->
      case previous_env do
        nil -> System.delete_env("SCOUT_AGENT_ID")
        value -> System.put_env("SCOUT_AGENT_ID", value)
      end
    end)

    System.put_env("SCOUT_AGENT_ID", "env-agent-1")

    Application.put_env(:gsmlg_scout, :settings, %{
      agent: %{id: "", region: "test"}
    })

    assert Settings.get()["agent"]["id"] == "env-agent-1"
  end

  test "falls back to generated agent id when configured and environment ids are blank" do
    previous_env = System.get_env("SCOUT_AGENT_ID")

    on_exit(fn ->
      case previous_env do
        nil -> System.delete_env("SCOUT_AGENT_ID")
        value -> System.put_env("SCOUT_AGENT_ID", value)
      end
    end)

    System.put_env("SCOUT_AGENT_ID", "")

    Application.put_env(:gsmlg_scout, :settings, %{
      agent: %{id: "", region: "test"}
    })

    id = Settings.get()["agent"]["id"]

    assert is_binary(id)
    assert id != ""
    assert String.starts_with?(id, "test-agent-")
  end
end
