defmodule GSMLG.Whois.CacheTest do
  use ExUnit.Case, async: false

  # Test the behaviour facade (delegates to Cache.ETS in test env)
  alias GSMLG.Whois.Cache

  setup do
    Cache.clear()
    :ok
  end

  describe "get/1 and put/3 via behaviour facade" do
    test "returns :miss for non-existent key" do
      assert Cache.get("nonexistent.com") == :miss
    end

    test "stores and retrieves a domain result" do
      assert :ok = Cache.put("example.com", "Domain Name: EXAMPLE.COM", :domain)
      assert {:ok, "Domain Name: EXAMPLE.COM"} = Cache.get("example.com")
    end

    test "stores and retrieves an IP result" do
      assert :ok = Cache.put("8.8.8.8", "NetRange: 8.0.0.0 - 8.255.255.255", :ip)
      assert {:ok, "NetRange: 8.0.0.0 - 8.255.255.255"} = Cache.get("8.8.8.8")
    end

    test "stores and retrieves an ASN result" do
      assert :ok = Cache.put("AS15169", "ASNumber: 15169", :asn)
      assert {:ok, "ASNumber: 15169"} = Cache.get("AS15169")
    end

    test "stores and retrieves an RDAP result (map value)" do
      rdap_data = %{"objectClassName" => "domain", "ldhName" => "EXAMPLE.COM"}
      assert :ok = Cache.put("rdap:example.com", rdap_data, :rdap)
      assert {:ok, ^rdap_data} = Cache.get("rdap:example.com")
    end

    test "overwrites existing value" do
      Cache.put("example.com", "First", :domain)
      Cache.put("example.com", "Second", :domain)
      assert {:ok, "Second"} = Cache.get("example.com")
    end
  end

  describe "expiration" do
    test "returns :miss for expired entry" do
      Application.put_env(:gsmlg_whois, :cache_ttl, %{domain: 1, ip: 1, asn: 1})

      Cache.put("short-ttl.com", "data", :domain)
      assert {:ok, _} = Cache.get("short-ttl.com")

      Process.sleep(5)
      assert Cache.get("short-ttl.com") == :miss
    after
      Application.delete_env(:gsmlg_whois, :cache_ttl)
    end
  end

  describe "clear/0" do
    test "removes all entries" do
      Cache.put("a.com", "a", :domain)
      Cache.put("b.com", "b", :domain)

      assert :ok = Cache.clear()

      assert Cache.get("a.com") == :miss
      assert Cache.get("b.com") == :miss
    end
  end

  describe "delete/1" do
    test "removes a single entry" do
      Cache.put("keep.com", "keep", :domain)
      Cache.put("del.com", "delete me", :domain)

      assert :ok = Cache.delete("del.com")

      assert {:ok, "keep"} = Cache.get("keep.com")
      assert Cache.get("del.com") == :miss
    end
  end

  describe "disabled cache" do
    test "returns :miss when cache is nil" do
      Application.put_env(:gsmlg_whois, :cache, nil)

      assert Cache.get("anything") == :miss
      assert Cache.put("anything", "value", :domain) == :ok
      assert Cache.clear() == :ok
    after
      Application.put_env(:gsmlg_whois, :cache, GSMLG.Whois.Cache.ETS)
    end
  end
end
