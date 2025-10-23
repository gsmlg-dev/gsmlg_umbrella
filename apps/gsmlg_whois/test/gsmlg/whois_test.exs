defmodule GSMLG.WhoisTest do
  use ExUnit.Case, async: false

  alias GSMLG.Whois
  alias GSMLG.Whois.Cache

  setup do
    Cache.clear()
    :ok
  end

  describe "cache integration" do
    test "returns cached result when available" do
      query = "cached.example.com"
      cached_data = [{"test.server", "Cached WHOIS data"}]

      Cache.put(query, cached_data, :domain)

      {:ok, result} = Whois.lookup_raw(query)
      assert result == cached_data
    end

    test "respects cache: false option" do
      query = "nocache.example.com"

      Cache.put(query, [{"server", "data"}], :domain)
      assert {:ok, _} = Cache.get(query)

      # With cache: false, should not use cached data
      # (will fail network lookup for fake domain, but that's ok)
      _result = Whois.lookup_raw(query, cache: false)
    end
  end

  describe "telemetry events" do
    test "emits cache hit event" do
      query = "telemetry.example.com"
      cached_data = [{"test.server", "Cached data"}]

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-cache-hit-#{ref}",
        [:gsmlg, :whois, :cache, :hit],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Cache.put(query, cached_data, :domain)
      {:ok, _result} = Whois.lookup_raw(query)

      assert_receive {:telemetry_event, [:gsmlg, :whois, :cache, :hit], %{},
                      %{query: ^query, type: :domain}},
                     1000

      :telemetry.detach("test-cache-hit-#{ref}")
    end

    test "emits cache miss event" do
      query = "miss.example.com"

      ref = make_ref()
      self_pid = self()

      :telemetry.attach(
        "test-cache-miss-#{ref}",
        [:gsmlg, :whois, :cache, :miss],
        fn event, measurements, metadata, _config ->
          send(self_pid, {:telemetry_event, event, measurements, metadata})
        end,
        nil
      )

      Cache.clear()
      _result = Whois.lookup_raw(query)

      assert_receive {:telemetry_event, [:gsmlg, :whois, :cache, :miss], %{},
                      %{query: ^query, type: :domain}},
                     1000

      :telemetry.detach("test-cache-miss-#{ref}")
    end
  end
end
