defmodule GSMLG.ProxyRules.StoreTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules.Store

  test "is protected and safe to read before publication" do
    assert :protected == :ets.info(:gsmlg_proxy_rules_store, :protection)
    assert true == :ets.info(:gsmlg_proxy_rules_store, :read_concurrency)
    assert [] == :ets.lookup(:gsmlg_proxy_rules_store, :current)
    assert {:error, :not_ready} == Store.current()
  end
end
