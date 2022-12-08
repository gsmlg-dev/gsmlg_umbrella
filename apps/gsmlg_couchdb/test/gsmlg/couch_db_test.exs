defmodule GSMLG.CouchDBTest do
  use ExUnit.Case
  doctest GSMLG.CouchDB

  test "greets the world" do
    assert GSMLG.CouchDB.hello() == :world
  end
end
