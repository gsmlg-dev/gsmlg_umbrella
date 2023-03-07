defmodule GSMLG.TorTest do
  use ExUnit.Case
  doctest GSMLG.Tor

  test "test generate tor default config" do
    GSMLG.Tor.Config.init()
    assert GSMLG.Tor.get_torrc() =~ "SOCKSPort 127.0.0.1:9050"
  end
end
