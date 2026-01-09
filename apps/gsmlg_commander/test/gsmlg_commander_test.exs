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
    test "returns keyword list with :url key" do
      opts = GSMLG.Commander.socket_opts()
      assert Keyword.has_key?(opts, :url)
    end

    test "returns keyword list with :params key" do
      opts = GSMLG.Commander.socket_opts()
      assert Keyword.has_key?(opts, :params)
    end

    test "returns :params as a map with required keys when configured" do
      # Setup test configuration
      Application.put_env(:gsmlg_commander, GSMLG.Commander,
        platform_url: "wss://test.example.com/agent",
        platform_key: "test_secret_key_for_testing",
        name: "test-agent"
      )

      opts = GSMLG.Commander.socket_opts()

      assert {:ok, url} = Keyword.fetch(opts, :url)
      assert url == "wss://test.example.com/agent"

      assert {:ok, params} = Keyword.fetch(opts, :params)
      assert is_map(params)
      assert Map.has_key?(params, :name)
      assert Map.has_key?(params, :signature)
      assert Map.has_key?(params, :sign_at)
      assert params.name == "test-agent"

      # Cleanup
      Application.delete_env(:gsmlg_commander, GSMLG.Commander)
    end
  end

  describe "agent_mode?/0" do
    test "returns false by default" do
      refute GSMLG.Commander.agent_mode?()
    end
  end

  describe "server_mode?/0" do
    test "returns true by default" do
      assert GSMLG.Commander.server_mode?()
    end
  end
end
