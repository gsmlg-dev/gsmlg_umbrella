defmodule GSMLG.Whois.ConcordCacheTest do
  use ExUnit.Case, async: false

  alias GSMLG.Whois.Cache.Concord, as: ConcordCache

  setup_all do
    {:ok, _} = Application.ensure_all_started(:concord)

    start_supervised!(
      {Concord.Engine.VSR.Supervisor,
       group_id: :whois_cache_test,
       replica_id: :whois_cache_test,
       members: [%{id: :whois_cache_test, endpoint: :whois_cache_test}],
       transport: :local,
       storage: :memory,
       bootstrap: true}
    )

    :ok
  end

  setup do
    prefix = "whois-cache-test:#{System.unique_integer([:positive])}:"
    [first, second] = keys = Enum.map(["first", "second"], &(prefix <> &1))

    on_exit(fn -> Enum.each(keys, &Concord.delete/1) end)

    %{first: first, second: second}
  end

  test "stores, overwrites, and deletes real Concord cache entries", %{first: key} do
    assert :miss = ConcordCache.get(key)
    assert :ok = ConcordCache.put(key, "WHOIS result", :domain, 60_000)
    assert {:ok, "WHOIS result"} = ConcordCache.get(key)

    rdap = %{"objectClassName" => "domain", "ldhName" => "EXAMPLE.COM"}
    assert :ok = ConcordCache.put(key, rdap, :rdap, 60_000)
    assert {:ok, ^rdap} = ConcordCache.get(key)

    assert :ok = ConcordCache.delete(key)
    assert :miss = ConcordCache.get(key)
    assert :ok = ConcordCache.delete(key)
  end

  test "converts milliseconds to seconds and expires the cached value", %{first: key} do
    assert :ok = ConcordCache.put(key, "short-lived", :domain, 1_000)
    assert {:ok, "short-lived"} = ConcordCache.get(key)
    assert {:ok, ttl} = Concord.ttl(key)
    assert ttl in 0..1

    assert :ok = await_expiry(key, System.monotonic_time(:millisecond) + 3_000)
    assert {:error, :not_found} = Concord.get(key)
  end

  test "clears entries from the real Concord backend", %{first: first, second: second} do
    # clear/0 targets the shared engine; this module runs serially in the test VM.
    assert :ok = ConcordCache.put(first, "first result", :domain, 60_000)
    assert :ok = ConcordCache.put(second, %{"handle" => "TEST"}, :rdap, 60_000)
    assert {:ok, "first result"} = ConcordCache.get(first)
    assert {:ok, %{"handle" => "TEST"}} = ConcordCache.get(second)

    assert :ok = ConcordCache.clear()
    assert :miss = ConcordCache.get(first)
    assert :miss = ConcordCache.get(second)
    assert {:error, :not_found} = Concord.get(first)
    assert {:error, :not_found} = Concord.get(second)
  end

  defp await_expiry(key, deadline) do
    case ConcordCache.get(key) do
      :miss ->
        :ok

      {:ok, _value} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "Concord cache entry did not expire within three seconds"

        Process.sleep(25)
        await_expiry(key, deadline)
    end
  end
end
