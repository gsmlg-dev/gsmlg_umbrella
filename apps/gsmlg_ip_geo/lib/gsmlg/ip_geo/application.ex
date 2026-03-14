defmodule GSMLG.IpGeo.Application do
  @moduledoc """
  OTP Application for GSMLG.IpGeo.

  Starts the database server that loads and serves MMDB database files
  for IP geolocation lookups.
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      GSMLG.IpGeo.Database
    ]

    opts = [strategy: :one_for_one, name: GSMLG.IpGeo.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
