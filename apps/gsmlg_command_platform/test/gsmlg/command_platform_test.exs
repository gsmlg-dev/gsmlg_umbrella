defmodule GSMLG.CommandPlatformTest do
  use ExUnit.Case
  doctest GSMLG.CommandPlatform

  test "greets the world" do
    assert GSMLG.CommandPlatform.hello() == :world
  end
end
