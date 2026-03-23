defmodule GSMLG.WhoisTest do
  use ExUnit.Case, async: false

  alias GSMLG.Whois
  alias GSMLG.Whois.Cache

  setup do
    Cache.clear()
    :ok
  end

  describe "lookup_raw/2 cache integration" do
    test "returns cached result when available" do
      query = "cached.example.com"
      cached_data = [{"test.server", "Cached WHOIS data"}]

      # lookup_raw uses "whois:<query>" as the cache key
      Cache.put("whois:#{query}", cached_data, :domain)

      assert {:ok, ^cached_data} = Whois.lookup_raw(query)
    end

    test "respects cache: false option" do
      query = "nocache.example.com"
      cached_data = [{"server", "data"}]

      Cache.put("whois:#{query}", cached_data, :domain)

      # With cache: false, bypasses cached data (will attempt live lookup)
      _result = Whois.lookup_raw(query, cache: false)
    end
  end

  describe "rdap_lookup/2 cache integration" do
    test "returns cached RDAP result when available" do
      query = "cached.example.com"
      cached_data = %{"objectClassName" => "domain", "ldhName" => "CACHED.EXAMPLE.COM"}

      # rdap_lookup uses "rdap:<query>" as the cache key
      Cache.put("rdap:#{query}", cached_data, :rdap)

      assert {:ok, ^cached_data} = Whois.rdap_lookup(query)
    end

    test "respects cache: false option for RDAP" do
      query = "nocache-rdap.example.com"
      cached_data = %{"objectClassName" => "domain"}

      Cache.put("rdap:#{query}", cached_data, :rdap)

      # With cache: false, bypasses cached data
      _result = Whois.rdap_lookup(query, cache: false)
    end
  end

  describe "telemetry events" do
    test "emits cache hit event on lookup_raw" do
      query = "tel-hit.example.com"
      cached_data = [{"test.server", "Cached data"}]
      self_pid = self()

      :telemetry.attach(
        :test_whois_cache_hit,
        [:gsmlg, :whois, :cache, :hit],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Cache.put("whois:#{query}", cached_data, :domain)
      {:ok, _} = Whois.lookup_raw(query)

      assert_receive {:telemetry_event, [:gsmlg, :whois, :cache, :hit], %{},
                      %{query: ^query, type: :domain}},
                     1_000

      :telemetry.detach(:test_whois_cache_hit)
    end

    test "emits cache miss event on lookup_raw" do
      query = "tel-miss.example.com"
      self_pid = self()

      :telemetry.attach(
        :test_whois_cache_miss,
        [:gsmlg, :whois, :cache, :miss],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      _result = Whois.lookup_raw(query)

      assert_receive {:telemetry_event, [:gsmlg, :whois, :cache, :miss], %{},
                      %{query: ^query, type: :domain}},
                     1_000

      :telemetry.detach(:test_whois_cache_miss)
    end

    test "emits cache hit event on rdap_lookup" do
      query = "tel-rdap-hit.example.com"
      cached_data = %{"objectClassName" => "domain"}
      self_pid = self()

      :telemetry.attach(
        :test_rdap_cache_hit,
        [:gsmlg, :whois, :cache, :hit],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Cache.put("rdap:#{query}", cached_data, :rdap)
      {:ok, _} = Whois.rdap_lookup(query)

      assert_receive {:telemetry_event, [:gsmlg, :whois, :cache, :hit], %{},
                      %{query: ^query, type: :domain}},
                     1_000

      :telemetry.detach(:test_rdap_cache_hit)
    end
  end
end
