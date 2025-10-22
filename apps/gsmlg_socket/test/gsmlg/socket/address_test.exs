defmodule GSMLG.Socket.AddressTest do
  use ExUnit.Case, async: true
  alias GSMLG.Socket.Address

  describe "parse/1" do
    test "parses IPv4 addresses from string" do
      assert {127, 0, 0, 1} = Address.parse("127.0.0.1")
      assert {192, 168, 1, 1} = Address.parse("192.168.1.1")
      assert {10, 0, 0, 1} = Address.parse("10.0.0.1")
    end

    test "parses IPv6 addresses from string" do
      assert {0, 0, 0, 0, 0, 0, 0, 1} = Address.parse("::1")
      assert {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1} = Address.parse("2001:db8::1")
    end

    test "parses from charlists" do
      assert {127, 0, 0, 1} = Address.parse(~c"127.0.0.1")
    end

    test "returns nil for invalid addresses" do
      assert nil == Address.parse("invalid")
      assert nil == Address.parse("999.999.999.999")
      assert nil == Address.parse("")
    end

    test "returns address tuple unchanged" do
      addr = {192, 168, 1, 1}
      assert ^addr = Address.parse(addr)
    end
  end

  describe "valid?/1" do
    test "validates IPv4 addresses" do
      assert Address.valid?("127.0.0.1")
      assert Address.valid?("192.168.1.1")
      refute Address.valid?("invalid")
      refute Address.valid?("999.999.999.999")
    end

    test "validates IPv6 addresses" do
      assert Address.valid?("::1")
      assert Address.valid?("2001:db8::1")
      refute Address.valid?("gggg::1")
    end
  end

  describe "to_string/1" do
    test "converts IPv4 tuple to string" do
      assert "127.0.0.1" = Address.to_string({127, 0, 0, 1})
      assert "192.168.1.1" = Address.to_string({192, 168, 1, 1})
    end

    test "converts IPv6 tuple to string" do
      result = Address.to_string({0, 0, 0, 0, 0, 0, 0, 1})
      assert result == "::1" or result == "0:0:0:0:0:0:0:1"
    end

    test "returns string unchanged" do
      assert "127.0.0.1" = Address.to_string("127.0.0.1")
    end

    test "converts charlist to string" do
      assert "127.0.0.1" = Address.to_string(~c"127.0.0.1")
    end
  end

  describe "is_in_subnet?/3" do
    test "IPv4 subnet matching" do
      assert Address.is_in_subnet?({192, 168, 1, 100}, {192, 168, 1, 0}, 24)
      assert Address.is_in_subnet?({192, 168, 1, 1}, {192, 168, 1, 0}, 24)
      refute Address.is_in_subnet?({192, 168, 2, 1}, {192, 168, 1, 0}, 24)
    end

    test "IPv4 different subnet sizes" do
      # /8 network
      assert Address.is_in_subnet?({10, 1, 2, 3}, {10, 0, 0, 0}, 8)
      refute Address.is_in_subnet?({11, 1, 2, 3}, {10, 0, 0, 0}, 8)

      # /16 network
      assert Address.is_in_subnet?({172, 16, 1, 1}, {172, 16, 0, 0}, 16)
      refute Address.is_in_subnet?({172, 17, 1, 1}, {172, 16, 0, 0}, 16)

      # /32 network (exact match)
      assert Address.is_in_subnet?({192, 168, 1, 1}, {192, 168, 1, 1}, 32)
      refute Address.is_in_subnet?({192, 168, 1, 2}, {192, 168, 1, 1}, 32)
    end

    test "IPv6 subnet matching" do
      addr1 = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
      addr2 = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2}
      net = {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 0}

      assert Address.is_in_subnet?(addr1, net, 64)
      assert Address.is_in_subnet?(addr2, net, 64)
    end
  end
end
