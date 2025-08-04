defmodule GSMLG.ConfigTest do
  use ExUnit.Case
  doctest GSMLG.Config

  test "greets the world" do
    assert GSMLG.Config.hello() == :world
  end
end
