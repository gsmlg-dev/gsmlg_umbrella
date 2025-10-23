defmodule GSMLG.Whois.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Start the cache GenServer
      GSMLG.Whois.Cache
    ]

    opts = [strategy: :one_for_one, name: GSMLG.Whois.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
