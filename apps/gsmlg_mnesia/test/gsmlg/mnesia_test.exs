defmodule GSMLG.Mnesia.Tests.GSMLG.Mnesia do
  use GSMLG.Mnesia.Support.Case
  @moduletag :mnesia

  describe "#add_nodes" do
    test "raises error when an atom is not passed" do
      assert_raise(GSMLG.Mnesia.Error, ~r/invalid node list/i, fn ->
        GSMLG.Mnesia.add_nodes(123)
      end)

      assert_raise(GSMLG.Mnesia.Error, ~r/invalid node list/i, fn ->
        GSMLG.Mnesia.add_nodes([:valid_node@host, "invalid_node@host"])
      end)
    end

    test "returns ok for valid atom list" do
      assert {:ok, []} = GSMLG.Mnesia.add_nodes(:nonexistent_node@host)
    end
  end
end
