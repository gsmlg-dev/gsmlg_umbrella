defmodule GSMLG.TorTest do
  use ExUnit.Case
  doctest GSMLG.Tor

  test "test tor download url" do
    assert GSMLG.Tor.download_url() =~ "https://dist.torproject.org/torbrowser/12.0/"
  end
end
