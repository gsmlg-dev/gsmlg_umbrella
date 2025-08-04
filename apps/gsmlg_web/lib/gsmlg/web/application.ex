defmodule GSMLG.Web.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GSMLG.Web.Telemetry,
      GSMLG.Web.Endpoint,
      {Absinthe.Subscription, [pubsub: GSMLG.Web.Endpoint]}
      # {Guardian.DB.Token.SweeperServer, []}
    ]

    opts = [strategy: :one_for_one, name: GSMLG.Web.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    GSMLG.Web.Endpoint.config_change(changed, removed)
    :ok
  end
end
