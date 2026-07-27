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

  test "rejects a live owner without detaching its same-id handler" do
    owner = self()
    handler_id = {__MODULE__, self(), make_ref()}
    first_name = {:global, {__MODULE__, :first, self(), make_ref()}}
    second_name = {:global, {__MODULE__, :second, self(), make_ref()}}

    first_broadcaster = fn _pubsub, _topic, message ->
      send(owner, {:first_bridge, message})
      :ok
    end

    second_broadcaster = fn _pubsub, _topic, message ->
      send(owner, {:second_bridge, message})
      :ok
    end

    assert {:ok, first} =
             ProxyRulesTelemetryBridge.start_link(
               name: first_name,
               handler_id: handler_id,
               broadcaster: first_broadcaster
             )

    {starter, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)

        result =
          ProxyRulesTelemetryBridge.start_link(
            name: second_name,
            handler_id: handler_id,
            broadcaster: second_broadcaster
          )

        send(owner, {:second_start, result})
      end)

    assert_receive {:second_start, {:error, :telemetry_handler_already_exists}}
    assert_receive {:DOWN, ^monitor, :process, ^starter, :normal}

    assert Process.alive?(first)
    assert handler_count(handler_id) == 1

    measurements = %{generation: 87}
    metadata = %{readiness: :ready}
    message = {:proxy_rules_status_changed, measurements, metadata}
    :telemetry.execute([:gsmlg, :proxy_rules, :status, :change], measurements, metadata)

    assert_receive {:first_bridge, ^message}
    refute_receive {:second_bridge, _message}
    assert Process.alive?(first)
    assert handler_count(handler_id) == 1

    GenServer.stop(first)
    assert handler_count(handler_id) == 0
  end

  test "serializes concurrent claims so exactly one bridge owns the handler" do
    owner = self()
    handler_id = {__MODULE__, self(), make_ref()}
    gate = make_ref()

    starters =
      for index <- 1..8 do
        spawn(fn ->
          Process.flag(:trap_exit, true)

          receive do
            ^gate ->
              result =
                ProxyRulesTelemetryBridge.start_link(
                  name: {:global, {__MODULE__, :concurrent, self(), index}},
                  handler_id: handler_id,
                  broadcaster: fn _pubsub, _topic, message ->
                    send(owner, {:concurrent_bridge, message})
                    :ok
                  end
                )

              send(owner, {:claim_result, result})
          end
        end)
      end

    Enum.each(starters, &send(&1, gate))

    deadline = System.monotonic_time(:millisecond) + 2_000
    results = collect_claim_results(length(starters), deadline)

    assert [{:ok, bridge}] = Enum.filter(results, &match?({:ok, _pid}, &1))

    assert Enum.count(results, &(&1 == {:error, :telemetry_handler_already_exists})) == 7
    assert handler_count(handler_id) == 1

    measurements = %{generation: 86}
    metadata = %{readiness: :ready}
    message = {:proxy_rules_status_changed, measurements, metadata}
    :telemetry.execute([:gsmlg, :proxy_rules, :status, :change], measurements, metadata)

    assert_receive {:concurrent_bridge, ^message}
    refute_receive {:concurrent_bridge, _message}

    GenServer.stop(bridge)
    assert handler_count(handler_id) == 0
  end

  test "reclaims a malformed stale same-id registration" do
    owner = self()
    handler_id = {__MODULE__, self(), make_ref()}
    event = [:gsmlg, :proxy_rules, :status, :change]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _event, _measurements, _metadata, _config -> send(owner, :legacy_handler) end,
        %{legacy: true}
      )

    assert {:ok, bridge} =
             ProxyRulesTelemetryBridge.start_link(
               name: {:global, {__MODULE__, :malformed, self(), make_ref()}},
               handler_id: handler_id,
               broadcaster: fn _pubsub, _topic, message ->
                 send(owner, message)
                 :ok
               end
             )

    measurements = %{generation: 85}
    metadata = %{readiness: :ready}
    message = {:proxy_rules_status_changed, measurements, metadata}
    :telemetry.execute(event, measurements, metadata)

    assert_receive ^message
    refute_receive :legacy_handler
    assert handler_count(handler_id) == 1

    GenServer.stop(bridge)
  end

  for {reason, down_reason} <- [{:boom, :boom}, {:kill, :killed}] do
    test "supervisor restarts the bridge after #{reason} with exactly one live handler" do
      reason = unquote(reason)
      down_reason = unquote(down_reason)
      handler_id = {__MODULE__, self(), make_ref()}
      global_key = {__MODULE__, reason, self(), make_ref()}
      name = {:global, global_key}
      topic = "proxy_rules:restart:#{System.unique_integer([:positive])}"

      supervisor =
        start_supervised!(%{
          id: {__MODULE__, reason, make_ref()},
          start:
            {Supervisor, :start_link,
             [
               [
                 {ProxyRulesTelemetryBridge, name: name, handler_id: handler_id, topic: topic}
               ],
               [strategy: :one_for_one]
             ]}
        })

      assert Process.alive?(supervisor)
      first = eventually_registered(global_key)
      monitor = Process.monitor(first)
      Process.exit(first, reason)
      assert_receive {:DOWN, ^monitor, :process, ^first, ^down_reason}

      restarted = eventually_restarted(global_key, first)
      assert Process.alive?(restarted)
      assert handler_count(handler_id) == 1

      Phoenix.PubSub.subscribe(GSMLG.PubSub, topic)
      measurements = %{generation: 88}
      metadata = %{readiness: :ready}
      :telemetry.execute([:gsmlg, :proxy_rules, :status, :change], measurements, metadata)

      assert_receive {:proxy_rules_status_changed, ^measurements, ^metadata}
      refute_receive {:proxy_rules_status_changed, _, _}
    end
  end

  test "broadcast failure cannot detach the handler and later delivery recovers" do
    owner = self()
    handler_id = {__MODULE__, self(), make_ref()}
    topic = "proxy_rules:recovery:#{System.unique_integer([:positive])}"
    {:ok, gate} = Agent.start_link(fn -> :fail end)

    broadcaster = fn pubsub, event_topic, message ->
      send(owner, {:broadcast_attempt, message})

      case Agent.get(gate, & &1) do
        :fail -> raise "controlled broadcaster failure"
        :ready -> Phoenix.PubSub.broadcast(pubsub, event_topic, message)
      end
    end

    bridge =
      start_supervised!(%{
        id: {__MODULE__, make_ref()},
        start:
          {ProxyRulesTelemetryBridge, :start_link,
           [
             [
               name: {:global, {__MODULE__, self(), make_ref()}},
               handler_id: handler_id,
               topic: topic,
               broadcaster: broadcaster
             ]
           ]},
        restart: :temporary
      })

    Phoenix.PubSub.subscribe(GSMLG.PubSub, topic)
    event = [:gsmlg, :proxy_rules, :status, :change]
    measurements = %{generation: 89}
    metadata = %{readiness: :stale}
    message = {:proxy_rules_status_changed, measurements, metadata}

    assert :ok = :telemetry.execute(event, measurements, metadata)
    assert_receive {:broadcast_attempt, ^message}
    assert Process.alive?(bridge)
    assert handler_count(handler_id) == 1

    Agent.update(gate, fn _state -> :ready end)
    assert :ok = :telemetry.execute(event, measurements, metadata)
    assert_receive {:broadcast_attempt, ^message}
    assert_receive ^message
    assert Process.alive?(bridge)
    assert handler_count(handler_id) == 1
  end

  defp handler_count(handler_id) do
    [:gsmlg, :proxy_rules, :status, :change]
    |> :telemetry.list_handlers()
    |> Enum.count(&(&1.id == handler_id))
  end

  defp collect_claim_results(count, deadline),
    do: do_collect_claim_results(count, count, deadline)

  defp do_collect_claim_results(0, _total, _deadline), do: []

  defp do_collect_claim_results(remaining, total, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:claim_result, result} ->
        [result | do_collect_claim_results(remaining - 1, total, deadline)]
    after
      timeout ->
        flunk(
          "received only #{total - remaining} of #{total} concurrent claim results within 2 seconds"
        )
    end
  end

  defp eventually_registered(global_key) do
    eventually(fn -> :global.whereis_name(global_key) end, fn
      pid when is_pid(pid) -> Process.alive?(pid)
      :undefined -> false
    end)
  end

  defp eventually_restarted(global_key, previous) do
    eventually(fn -> :global.whereis_name(global_key) end, fn
      pid when is_pid(pid) -> pid != previous and Process.alive?(pid)
      :undefined -> false
    end)
  end

  defp eventually(fun, predicate) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_eventually(fun, predicate, deadline)
  end

  defp do_eventually(fun, predicate, deadline) do
    value = fun.()

    cond do
      predicate.(value) ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met: #{inspect(value)}")

      true ->
        Process.sleep(10)
        do_eventually(fun, predicate, deadline)
    end
  end
end
