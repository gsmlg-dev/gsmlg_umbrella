defmodule GSMLG_CouchDBTest do
  use ExUnit.Case
  doctest GSMLG_CouchDB

  test "greets the world" do
    assert GSMLG_CouchDB.hello() == :world
  end
end
