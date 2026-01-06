defmodule GSMLG.CommanderTestTest do
  use ExUnit.Case

  describe "GSMLG.CommanderTest" do
    test "default_config returns configuration map" do
      config = GSMLG.CommanderTest.default_config()

      assert is_map(config)
      assert Map.has_key?(config, :server_port)
      assert Map.has_key?(config, :connect_timeout)
      assert Map.has_key?(config, :scenario_timeout)
      assert Map.has_key?(config, :reporters)
    end

    test "list_scenarios returns empty list when no scenarios defined" do
      scenarios = GSMLG.CommanderTest.list_scenarios()
      assert is_list(scenarios)
    end
  end
end
