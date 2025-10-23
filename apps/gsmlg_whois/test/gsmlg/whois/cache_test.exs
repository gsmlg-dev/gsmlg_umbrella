defmodule GSMLG.Whois.CacheTest do
  use ExUnit.Case, async: false

  alias GSMLG.Whois.Cache

  setup do
    Cache.clear()
    :ok
  end

  describe "get/1 and put/3" do
    test "returns :miss for non-existent key" do
      assert Cache.get("nonexistent.com") == :miss
    end

    test "stores and retrieves a domain result" do
      key = "example.com"
      value = "Domain Name: EXAMPLE.COM\nRegistrar: Example Inc."

      assert :ok = Cache.put(key, value, :domain)
      assert {:ok, ^value} = Cache.get(key)
    end

    test "stores and retrieves an IP result" do
      key = "8.8.8.8"
      value = "NetRange: 8.0.0.0 - 8.255.255.255\nNetName: LVLT-ORG-8-8"

      assert :ok = Cache.put(key, value, :ip)
      assert {:ok, ^value} = Cache.get(key)
    end

    test "stores and retrieves an ASN result" do
      key = "AS15169"
      value = "ASNumber: 15169\nASName: GOOGLE"

      assert :ok = Cache.put(key, value, :asn)
      assert {:ok, ^value} = Cache.get(key)
    end

    test "overwrites existing value" do
      key = "example.com"
      value1 = "First result"
      value2 = "Second result"

      Cache.put(key, value1, :domain)
      assert {:ok, ^value1} = Cache.get(key)

      Cache.put(key, value2, :domain)
      assert {:ok, ^value2} = Cache.get(key)
    end

    test "handles multiple keys independently" do
      Cache.put("example1.com", "Result 1", :domain)
      Cache.put("example2.com", "Result 2", :domain)
      Cache.put("8.8.8.8", "Result 3", :ip)

      assert {:ok, "Result 1"} = Cache.get("example1.com")
      assert {:ok, "Result 2"} = Cache.get("example2.com")
      assert {:ok, "Result 3"} = Cache.get("8.8.8.8")
    end
  end

  describe "expiration" do
    test "returns :miss for expired entry" do
      key = "short-ttl.com"
      value = "Test data"

      original_ttl = Application.get_env(:gsmlg_whois, :cache_ttl, %{})

      Application.put_env(:gsmlg_whois, :cache_ttl, %{
        domain: 1,
        ip: 1,
        asn: 1
      })

      Cache.put(key, value, :domain)
      assert {:ok, ^value} = Cache.get(key)

      Process.sleep(5)
      assert Cache.get(key) == :miss

      Application.put_env(:gsmlg_whois, :cache_ttl, original_ttl)
    end
  end

  describe "clear/0" do
    test "removes all entries from cache" do
      Cache.put("example1.com", "Data 1", :domain)
      Cache.put("example2.com", "Data 2", :domain)
      Cache.put("8.8.8.8", "Data 3", :ip)

      assert Cache.stats().size == 3
      assert :ok = Cache.clear()
      assert Cache.stats().size == 0
    end
  end

  describe "stats/0" do
    test "returns correct size" do
      assert Cache.stats().size == 0

      Cache.put("example1.com", "Data 1", :domain)
      assert Cache.stats().size == 1

      Cache.put("example2.com", "Data 2", :domain)
      assert Cache.stats().size == 2

      Cache.clear()
      assert Cache.stats().size == 0
    end

    test "returns memory usage" do
      stats = Cache.stats()
      assert is_integer(stats.memory_bytes)
      assert stats.memory_bytes >= 0
    end

    test "returns enabled status" do
      stats = Cache.stats()
      assert stats.enabled == true
    end
  end

  describe "has_key?/1" do
    test "returns true for existing key" do
      key = "example.com"
      Cache.put(key, "data", :domain)
      assert Cache.has_key?(key) == true
    end

    test "returns false for non-existent key" do
      assert Cache.has_key?("nonexistent.com") == false
    end
  end

  describe "concurrent access" do
    test "handles multiple concurrent reads and writes" do
      key = "concurrent.com"
      value = "concurrent data"

      Cache.put(key, value, :domain)

      tasks =
        for _ <- 1..10 do
          Task.async(fn ->
            Cache.get(key)
          end)
        end

      results = Task.await_many(tasks)
      assert Enum.all?(results, fn result -> result == {:ok, value} end)
    end

    test "handles concurrent writes to different keys" do
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            Cache.put("key#{i}.com", "value#{i}", :domain)
          end)
        end

      Task.await_many(tasks)

      for i <- 1..10 do
        assert {:ok, "value#{i}"} = Cache.get("key#{i}.com")
      end
    end
  end
end
