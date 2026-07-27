defmodule GSMLG.ProxyRulesTest do
  use ExUnit.Case, async: false

  alias GSMLG.ProxyRules
  alias GSMLG.ProxyRules.{Compiler, Output, Store}

  test "returns not-ready for every valid artifact lookup before publication" do
    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash] do
      assert {:error, :not_ready} == ProxyRules.get_artifact(list, format)
      assert {:error, :not_ready} == ProxyRules.get_artifact_response(list, format)
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
    assert {:error, :not_found} == ProxyRules.get_artifact_response(:unknown, :raw)
    assert {:error, :not_found} == ProxyRules.get_artifact_response(:proxy, :unknown)
  end

  test "returns a typed output from one complete current snapshot" do
    assert {:ok, snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 42,
               compiled_at: ~U[2026-07-23 00:00:00Z],
               sample_limit: 2
             )

    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        :ets.delete(:gsmlg_proxy_rules_store, :current)
        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)

    assert {:ok, %Output{body: body}} = ProxyRules.get_artifact(:proxy, :raw)
    assert body =~ "proxy.example"
  end

  test "returns generation and output from the same current snapshot" do
    prior = Store.current()

    assert {:ok, snapshot} =
             Compiler.compile(
               %{
                 remote: Base.encode64("||remote.example^\n"),
                 local_proxy: "proxy.example\n",
                 local_direct: "direct.example\n"
               },
               generation: 43,
               compiled_at: ~U[2026-07-23 00:00:00Z],
               sample_limit: 2
             )

    on_exit(fn ->
      :sys.replace_state(Store, fn state ->
        case prior do
          {:ok, prior_snapshot} ->
            :ets.insert(:gsmlg_proxy_rules_store, {:current, prior_snapshot})

          {:error, :not_ready} ->
            :ets.delete(:gsmlg_proxy_rules_store, :current)
        end

        state
      end)
    end)

    :sys.replace_state(Store, fn state ->
      :ets.insert(:gsmlg_proxy_rules_store, {:current, snapshot})
      state
    end)

    assert {:ok, %{generation: 43, output: %Output{body: body}}} =
             ProxyRules.get_artifact_response(:direct, :raw)

    assert body =~ "direct.example"
  end

  test "reports not-ready metadata without fabricated counts" do
    assert {:ok, %{readiness: readiness, sources: sources}} = ProxyRules.metadata()
    assert readiness in [:not_ready, :refreshing, :stale, :ready]

    assert %{
             remote_gfwlist: %{label: "Remote GFWList"},
             local_proxy: %{label: "Local proxy list"},
             local_direct: %{label: "Local direct list"}
           } = sources
  end

  test "accepts a refresh while the source service is available" do
    assert {:ok, :accepted} == ProxyRules.refresh()
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
    assert {:ok, metadata} = ProxyRules.metadata()
    refute Map.has_key?(metadata, :sources)
  end
end
