defmodule GSMLG.AdminWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      GSMLG.AdminWeb.Telemetry,
      # Bridge Caddy telemetry events to PubSub for LiveView consumption
      GSMLG.AdminWeb.CaddyTelemetryCollector,
      {GSMLG.GaoNote.MCP.AdminServer, transport: {:streamable_http, start: true}},
      GSMLG.AdminWeb.ProxyRulesTelemetryBridge,
      # Start the Endpoint (http/https)
      GSMLG.AdminWeb.Endpoint,
      {Guardian.DB.Sweeper, []}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GSMLG.AdminWeb.Supervisor]
    result = Supervisor.start_link(children, opts)
    GSMLG.Caddy.setup_admin_proxy()
    result
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GSMLG.AdminWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
