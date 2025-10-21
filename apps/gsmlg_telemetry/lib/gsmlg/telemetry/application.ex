defmodule GSMLG.Telemetry.Application do
  @moduledoc """
  Application module for GSMLG.Telemetry.

  This module defines the supervision tree for the telemetry system,
  including handlers, reporters, and backends.
  """

  use Application

  alias GSMLG.Telemetry.{Handler, Reporter, Metrics}
  alias GSMLG.Telemetry.Backends.{Console, File, CloudWatch}

  @impl true
  def start(_type, _args) do
    config = Application.get_all_env(:gsmlg_telemetry)

    children = [
      # Metrics collector
      {Metrics, config},
      # Metrics reporter
      {Reporter, config},
      # Telemetry poller for VM metrics
      start_telemetry_poller(config),
      # Event handler
      {Handler, config},
      # Backends
      start_backends(config)
    ]

    opts = [strategy: :one_for_one, name: GSMLG.Telemetry.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_telemetry_poller(config) do
    poller_config = Keyword.get(config, :telemetry_poller, [])

    default_measurements = [
      {Telemetry.Poller, :measure_memory, []},
      {Telemetry.Poller, :measure_total_run_queue_lengths, []},
      {Telemetry.Poller, :measure_system_counts, []}
    ]

    measurements = Keyword.get(poller_config, :measurements, default_measurements)
    period = Keyword.get(poller_config, :period, 5_000)
    name = Keyword.get(poller_config, :name, TelemetryPoller)

    %{
      id: name,
      start: {
        Telemetry.Poller,
        :start_link,
        [[measurements: measurements, period: period, name: name]]
      }
    }
  end

  defp start_backends(config) do
    backends_config = Keyword.get(config, :backends, [])

    backends = []
    |> maybe_add_console_backend(backends_config)
    |> maybe_add_file_backend(backends_config)
    |> maybe_add_cloudwatch_backend(backends_config)

    # Wrap each backend in a supervisor to handle failures
    Enum.map(backends, fn backend_config ->
      %{
        id: backend_config.id,
        start: {backend_config.module, :start_link, [backend_config.opts]}
      }
    end)
  end

  defp maybe_add_console_backend(backends, backends_config) do
    console_config = Keyword.get(backends_config, :console, [])
    enabled = Keyword.get(console_config, :enabled, true)

    if enabled do
      [
        %{
          id: Console,
          module: Console,
          opts: console_config
        }
        | backends
      ]
    else
      backends
    end
  end

  defp maybe_add_file_backend(backends, backends_config) do
    file_config = Keyword.get(backends_config, :file, [])
    enabled = Keyword.get(file_config, :enabled, false)

    if enabled do
      [
        %{
          id: File,
          module: File,
          opts: file_config
        }
        | backends
      ]
    else
      backends
    end
  end

  defp maybe_add_cloudwatch_backend(backends, backends_config) do
    cloudwatch_config = Keyword.get(backends_config, :cloudwatch, [])
    enabled = Keyword.get(cloudwatch_config, :enabled, false)

    if enabled do
      [
        %{
          id: CloudWatch,
          module: CloudWatch,
          opts: cloudwatch_config
        }
        | backends
      ]
    else
      backends
    end
  end
end