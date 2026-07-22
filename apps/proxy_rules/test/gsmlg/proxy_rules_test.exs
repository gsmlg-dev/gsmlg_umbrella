defmodule GSMLG.ProxyRulesTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules
  alias GSMLG.ProxyRules.Store

  test "returns not-ready for every valid artifact lookup before publication" do
    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash] do
      assert {:error, :not_ready} == ProxyRules.get_artifact(list, format)
    end
  end

  test "returns not-found when the current snapshot lacks rendered outputs" do
    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        :ets.delete(:gsmlg_proxy_rules_store, :current)
        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, %{}})
      state
    end)

    assert {:error, :not_found} == ProxyRules.get_artifact(:proxy, :raw)
  end

  test "rejects unsupported list and renderer identifiers" do
    assert {:error, :not_found} == ProxyRules.get_artifact(:unknown, :raw)
    assert {:error, :not_found} == ProxyRules.get_artifact(:proxy, :unknown)
  end

  test "reports not-ready metadata without fabricated counts" do
    assert {:error, :not_ready} == ProxyRules.metadata()
  end

  test "reports refresh unavailable before source ingestion exists" do
    assert {:error, :not_available} == ProxyRules.refresh()
  end

  test "reports refresh unavailable while the coordinator is unavailable" do
    assert :ok =
             Supervisor.terminate_child(
               GSMLG.ProxyRules.Supervisor,
               GSMLG.ProxyRules.Coordinator
             )

    on_exit(fn ->
      case Supervisor.restart_child(
             GSMLG.ProxyRules.Supervisor,
             GSMLG.ProxyRules.Coordinator
           ) do
        {:ok, _pid} -> :ok
        {:ok, _pid, _info} -> :ok
        {:error, :running} -> :ok
      end
    end)

    assert {:error, :not_available} == ProxyRules.refresh()
  end
end
