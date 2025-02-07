defmodule GSMLG.ComponentTest do
  use ExUnit.Case
  doctest GSMLG.Component

  test "greets the world" do
    assert GSMLG.Component.hello() == :world
  end
end
