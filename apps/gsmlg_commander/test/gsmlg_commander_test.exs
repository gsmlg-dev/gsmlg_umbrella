defmodule GSMLG.Commander.Test do
  @moduledoc """
  Tests for the GSMLG.Commander module.

  Note: Named GSMLG.Commander.Test (not GSMLG.CommanderTest) to avoid
  conflict with the GSMLG.CommanderTest testing framework module in
  the gsmlg_commander_test app.
  """
  use ExUnit.Case
  doctest GSMLG.Commander

  describe "socket_opts/0" do
    setup do
      # Store original config to restore later
      original_config = Application.get_env(:gsmlg_commander, GSMLG.Commander)

      # Setup test configuration
      Application.put_env(:gsmlg_commander, GSMLG.Commander,
        platform_url: "wss://test.example.com/agent",
        platform_key: "test_secret_key_for_testing",
        name: "test-agent",
        credential_id: "test-agent-credential"
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

    test "returns keyword list with :url key" do
      opts = GSMLG.Commander.socket_opts()
      assert Keyword.has_key?(opts, :url)
    end

    test "defers authentication parameters until each transport connection" do
      opts = GSMLG.Commander.socket_opts()
      assert opts[:transport] == GSMLG.Commander.Transport
      assert opts[:params] == %{}
      refute inspect(opts) =~ "test_secret_key_for_testing"
    end

    test "does not expose socket transport or message payloads through dependency telemetry" do
      original = Application.get_env(:phoenix_socket_client, :telemetry)

      on_exit(fn ->
        if original do
          Application.put_env(:phoenix_socket_client, :telemetry, original)
        else
          Application.delete_env(:phoenix_socket_client, :telemetry)
        end
      end)

      assert :ok = GSMLG.Commander.configure_socket_telemetry()
      assert Phoenix.SocketClient.Telemetry.enabled?() == false
    end

    test "rejects malformed and non-WebSocket URLs" do
      config = Application.fetch_env!(:gsmlg_commander, GSMLG.Commander)

      for url <- ["https://test.example.com/agent", "wss:///agent", "not a url"] do
        assert_raise ArgumentError, ~r/platform_url/, fn ->
          GSMLG.Commander.socket_opts(Keyword.put(config, :platform_url, url))
        end
      end
    end
  end

  describe "agent_mode?/0" do
    test "returns false by default" do
      refute GSMLG.Commander.agent_mode?()
    end
  end

  describe "server_mode?/0" do
    test "fails closed when server mode is not explicitly enabled" do
      refute GSMLG.Commander.server_mode?()
    end
  end

  describe "configured_features/1" do
    test "defaults to pty feature" do
      assert GSMLG.Commander.configured_features([]) == [:pty]
    end

    test "normalizes supported feature strings" do
      assert GSMLG.Commander.configured_features(features: ["pty", :pty, "unknown"]) == [:pty]
    end
  end

  describe "max_in_flight_rpcs/1" do
    test "uses a finite default matching one advertised session plus one workflow" do
      assert GSMLG.Commander.max_in_flight_rpcs([]) == 2
      assert GSMLG.Commander.max_in_flight_rpcs(max_in_flight_rpcs: 5) == 5
    end
  end
end
