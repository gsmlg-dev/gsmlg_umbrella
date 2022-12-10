defmodule GSMLG.MACTest do
  use ExUnit.Case
  doctest GSMLG.MAC

  test "greets the world" do
    assert GSMLG.MAC.lookup_vendor("00:00:0A:BB:28:FC") ==
             {:ok, "OmronTat", "Omron Tateisi Electronics Co."}
  end
end
