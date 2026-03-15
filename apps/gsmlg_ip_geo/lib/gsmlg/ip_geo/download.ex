defmodule GSMLG.IpGeo.Download do
  @moduledoc """
  Downloads DB-IP.com geolocation databases.

  Can be called in release mode via eval:

      ./bin/gsmlg_umbrella eval "GSMLG.IpGeo.Download.run()"
      ./bin/gsmlg_umbrella eval "GSMLG.IpGeo.Download.run(:city)"
      ./bin/gsmlg_umbrella eval "GSMLG.IpGeo.Download.run(:country, force: true)"

  ## Options

    - `:force` - Overwrite existing database file (default: `false`)

  ## Configuration

      config :gsmlg_ip_geo,
        databases: %{
          city: "/custom/path/city.mmdb",
          country: "/custom/path/country.mmdb"
        }
  """

  require Logger

  @db_ip_base_url "https://download.db-ip.com/free"

  @doc """
  Downloads both city and country databases.
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    load_app()
    Application.ensure_all_started(:http_fetch)

    for type <- [:city, :country] do
      case download(type, opts) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error("[GSMLG.IpGeo.Download] Failed",
            type: type,
            error: inspect(reason)
          )
      end
    end

    :ok
  end

  @doc """
  Downloads a single database by type (`:city` or `:country`).
  """
  @spec run(atom(), keyword()) :: :ok | {:error, term()}
  def run(type, opts) when is_atom(type) do
    load_app()
    Application.ensure_all_started(:http_fetch)
    download(type, opts)
  end

  # Private

  defp download(type, opts) do
    target_path = resolve_path(type)

    if File.exists?(target_path) and !opts[:force] do
      Logger.info("[GSMLG.IpGeo.Download] Database already exists, skipping", path: target_path)
      :ok
    else
      fetch_and_save(type, target_path)
    end
  end

  defp resolve_path(type) do
    configured = Application.get_env(:gsmlg_ip_geo, :databases, %{})

    case Map.get(configured, type) do
      nil ->
        priv_dir = :code.priv_dir(:gsmlg_ip_geo)
        Path.join([priv_dir, "data", "dbip-#{type}-lite.mmdb"])

      path ->
        if Path.type(path) == :absolute do
          path
        else
          priv_dir = :code.priv_dir(:gsmlg_ip_geo)
          Path.join([priv_dir, "data", path])
        end
    end
  end

  defp fetch_and_save(type, target_path) do
    File.mkdir_p!(Path.dirname(target_path))

    {{year, month, _}, _} = :calendar.universal_time()
    month_str = String.pad_leading("#{month}", 2, "0")
    url = "#{@db_ip_base_url}/dbip-#{type}-lite-#{year}-#{month_str}.mmdb.gz"

    Logger.info("[GSMLG.IpGeo.Download] Downloading", type: type, url: url)

    case HTTP.fetch(url) |> HTTP.Promise.await() do
      %HTTP.Response{ok: true, body: body} ->
        decompress_and_save(body, target_path)

      %HTTP.Response{status: status} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decompress_and_save(compressed, target_path) do
    case :zlib.gunzip(compressed) do
      data when is_binary(data) ->
        File.write!(target_path, data)
        Logger.info("[GSMLG.IpGeo.Download] Saved database", path: target_path)
        :ok

      _ ->
        {:error, :decompress_failed}
    end
  end

  defp load_app do
    Application.load(:gsmlg_ip_geo)
  end
end
