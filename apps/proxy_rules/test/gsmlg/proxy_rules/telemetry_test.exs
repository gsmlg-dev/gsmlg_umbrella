defmodule GSMLG.ProxyRules.TelemetryTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.{Diagnostic, Snapshot, Telemetry, Transport}

  defmodule TestLogger do
    def log(level, message, opts) do
      send(self(), {:sample_log, level, message, opts})
      :ok
    end
  end

  test "emit prefixes a valid bounded event" do
    handler_id = {__MODULE__, self()}
    event = [:gsmlg, :proxy_rules, :remote, :fetch, :stop]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, pid ->
          send(pid, {:event, name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = Telemetry.emit([:remote, :fetch, :stop], %{duration: 10}, %{status: 200})
    assert_receive {:event, ^event, %{duration: 10}, %{status: 200}}
  end

  test "emit uses the status change suffix consumed by the telemetry bridge" do
    handler_id = {__MODULE__, self()}
    event = [:gsmlg, :proxy_rules, :status, :change]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn name, measurements, metadata, pid ->
          send(pid, {:event, name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             Telemetry.emit([:status, :change], %{generation: 7}, %{readiness: :ready})

    assert_receive {:event, ^event, %{generation: 7}, %{readiness: :ready}}

    assert {:error, :invalid_metadata} =
             Telemetry.emit([:status, :change], %{generation: 7}, %{readiness: :unknown})

    assert {:error, :invalid_event} =
             Telemetry.emit([:readiness, :status, :change], %{generation: 7}, %{})
  end

  test "emit rejects malformed suffixes, measurements, and metadata without executing" do
    handler_id = {__MODULE__, self()}
    event = [:gsmlg, :proxy_rules, :remote, :fetch, :stop]

    :ok =
      :telemetry.attach(handler_id, event, fn _, _, _, pid -> send(pid, :executed) end, self())

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, :invalid_event} = Telemetry.emit([:remote, :fetch, :unknown], %{}, %{})

    assert {:error, :invalid_measurements} =
             Telemetry.emit([:remote, :fetch, :stop], %{duration: -1}, %{})

    assert {:error, :invalid_metadata} =
             Telemetry.emit([:remote, :fetch, :stop], %{}, %{body: "secret source body"})

    refute_receive :executed
  end

  test "every finite transport failure crosses snapshot and telemetry boundaries" do
    handler_id = {__MODULE__, self()}
    event = [:gsmlg, :proxy_rules, :remote, :fetch, :exception]

    :ok =
      :telemetry.attach(
        handler_id,
        event,
        fn _name, _measurements, metadata, pid -> send(pid, {:failure, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    for reason <- Transport.error_reasons() do
      assert Snapshot.valid_operational_error?(%{kind: :remote, reason: reason})

      assert :ok =
               Telemetry.emit([:remote, :fetch, :exception], %{}, %{
                 failure_category: reason
               })

      assert_receive {:failure, %{failure_category: ^reason}}
    end
  end

  test "sample_log logs only indices below the limit with bounded metadata" do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:gsmlg, :log],
        fn name, measurements, metadata, pid ->
          send(pid, {:shared_log, name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    diagnostic = %Diagnostic{
      kind: :unsupported,
      source: :gfwlist,
      location: 19,
      reason: :wildcard,
      sample: :binary.copy("x", 700)
    }

    assert :ok = Telemetry.sample_log(:info, diagnostic, 0, 1, GSMLG.Telemetry)

    assert_receive {:shared_log, [:gsmlg, :log], %{level: :info},
                    %{
                      category: :unsupported,
                      source: :gfwlist,
                      location: 19,
                      sample: sample,
                      message: "proxy rules diagnostic sample"
                    }}

    assert byte_size(sample) == 512
    assert String.ends_with?(sample, "...[truncated]")

    assert :ok = Telemetry.sample_log(:info, diagnostic, 1, 1, GSMLG.Telemetry)
    refute_receive {:shared_log, _, _, _}
  end

  test "sample_log rejects invalid inputs without logging arbitrary data" do
    diagnostic = %Diagnostic{
      kind: :systemic,
      source: :gfwlist,
      location: :system,
      reason: :systemic_failure,
      sample: "complete source body"
    }

    assert {:error, :invalid_sample_log} =
             Telemetry.sample_log(:notice, diagnostic, 0, 1, TestLogger)

    assert {:error, :invalid_sample_log} =
             Telemetry.sample_log(:error, diagnostic, 0, 1, TestLogger)

    assert {:error, :invalid_sample_log} =
             Telemetry.sample_log(:error, %{diagnostic | source: :attacker}, 0, 1, TestLogger)

    assert {:error, :invalid_sample_log} =
             Telemetry.sample_log(:error, %{diagnostic | kind: :invalid}, 0, 1, :not_a_logger)

    refute_receive {:sample_log, _, _, _}
  end
end
