defmodule GSMLG.AdminWeb.ProxyRulesTelemetryBridgeTest do
  use ExUnit.Case, async: false

  alias GSMLG.AdminWeb.ProxyRulesTelemetryBridge

  test "broadcasts bounded status, publication, restoration, and failure events" do
    Phoenix.PubSub.subscribe(GSMLG.PubSub, ProxyRulesTelemetryBridge.topic())

    events = [
      {[:status, :change], %{generation: 3}, %{readiness: :ready}},
      {[:artifact, :publication], %{generation: 3, artifact_size: 120}, %{}},
      {[:artifact, :restoration], %{generation: 3}, %{}},
      {[:compile, :exception], %{duration: 12}, %{failure_category: :compile_failed}}
    ]

    for {suffix, measurements, metadata} <- events do
      :telemetry.execute([:gsmlg, :proxy_rules] ++ suffix, measurements, metadata)

      assert_receive {:proxy_rules_status_changed, ^measurements, ^metadata}
    end
  end

  test "does not broadcast unrelated telemetry or unbounded payload fields" do
    Phoenix.PubSub.subscribe(GSMLG.PubSub, ProxyRulesTelemetryBridge.topic())

    :telemetry.execute([:gsmlg, :other, :status, :change], %{generation: 8}, %{
      readiness: :ready
    })

    refute_receive {:proxy_rules_status_changed, _, _}

    :telemetry.execute(
      [:gsmlg, :proxy_rules, :api, :artifact, :hit],
      %{generation: 8},
      %{list: :proxy, format: :raw, status: 200}
    )

    refute_receive {:proxy_rules_status_changed, _, _}

    :telemetry.execute(
      [:gsmlg, :proxy_rules, :status, :change],
      %{generation: 8, body: String.duplicate("secret", 1_000)},
      %{readiness: :stale, source_url: "https://secret.example/rules"}
    )

    assert_receive {:proxy_rules_status_changed, %{generation: 8}, %{readiness: :stale}}
  end

  test "detaches its unique telemetry handler on shutdown" do
    handler_id = {__MODULE__, self(), make_ref()}
    name = {:global, {__MODULE__, self(), make_ref()}}

    assert {:ok, bridge} =
             ProxyRulesTelemetryBridge.start_link(name: name, handler_id: handler_id)

    assert Enum.any?(:telemetry.list_handlers([:gsmlg, :proxy_rules, :status, :change]), fn
             %{id: ^handler_id} -> true
             _handler -> false
           end)

    GenServer.stop(bridge)

    refute Enum.any?(:telemetry.list_handlers([:gsmlg, :proxy_rules, :status, :change]), fn
             %{id: ^handler_id} -> true
             _handler -> false
           end)
  end
end
