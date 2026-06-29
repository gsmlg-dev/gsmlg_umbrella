defmodule GSMLG.Scout.SettingsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Fetch.Job
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

  test "configured blocked CIDRs cannot narrow the built-in SSRF denylist" do
    Application.put_env(:gsmlg_scout, :settings, %{
      security: %{blocked_cidrs: ["127.0.0.0/8", "203.0.113.0/24"]}
    })

    blocked_cidrs = Settings.get()["security"]["blocked_cidrs"]

    assert "0.0.0.0/8" in blocked_cidrs
    assert "::/128" in blocked_cidrs
    assert "203.0.113.0/24" in blocked_cidrs
    assert Enum.count(blocked_cidrs, &(&1 == "127.0.0.0/8")) == 1
  end

  test "configured URL schemes cannot widen the HTTP boundary" do
    Application.put_env(:gsmlg_scout, :settings, %{
      security: %{allowed_schemes: ["HTTP", "https", "file", "ftp"]}
    })

    assert Settings.get()["security"]["allowed_schemes"] == ["http", "https"]
  end

  test "short configured CIDR list still blocks unspecified targets" do
    Application.put_env(:gsmlg_scout, :settings, %{
      security: %{blocked_cidrs: ["127.0.0.0/8"]}
    })

    settings = Settings.get()

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://0.0.0.0:4000"}, settings)

    assert {:error, %{type: "blocked_target"}} =
             Job.new(%{"url" => "http://[::]/"}, settings)
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
