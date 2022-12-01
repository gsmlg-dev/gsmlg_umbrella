defmodule GSMLG.WhoisTest do
  use ExUnit.Case
  doctest GSMLG.Whois

  test "greets the world" do
    assert GSMLG.Whois.hello() == :world
  end
end
