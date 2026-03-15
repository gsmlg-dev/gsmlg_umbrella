defmodule Mix.Tasks.GsmlgIpGeo.Download do
  @moduledoc """
  Downloads the DB-IP.com geolocation database.

  ## Usage

      mix gsmlg_ip_geo.download
      mix gsmlg_ip_geo.download --country
      mix gsmlg_ip_geo.download --force

  ## Options

      --force    Overwrite existing database file
      --country  Download country-only database (smaller, faster)
  """

  use Mix.Task

  @shortdoc "Downloads the DB-IP.com geolocation database"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, switches: [force: :boolean, country: :boolean])

    Application.ensure_all_started(:http_fetch)

    type = if opts[:country], do: :country, else: :city
    download_opts = if opts[:force], do: [force: true], else: []

    GSMLG.IpGeo.Download.run(type, download_opts)
  end
end
