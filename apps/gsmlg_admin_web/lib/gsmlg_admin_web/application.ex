defmodule GSMLGAdminWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the Telemetry supervisor
      GSMLGAdminWeb.Telemetry,
      # Start the Endpoint (http/https)
      GSMLGAdminWeb.Endpoint,
      # GraphQL subscriptions
      {Absinthe.Subscription, [GSMLGAdminWeb.Endpoint]},
      {Guardian.DB.Token.SweeperServer, []}
      # Start a worker by calling: GSMLGAdminWeb.Worker.start_link(arg)
      # {GSMLGAdminWeb.Worker, arg}
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: GSMLGAdminWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    GSMLGAdminWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
