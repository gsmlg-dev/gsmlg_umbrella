defmodule GSMLG.IpGeo.Download do
  @moduledoc """
  Downloads DB-IP.com geolocation databases for use in releases.

  This module is designed to be called via release eval commands:

      ./bin/gsmlg_umbrella eval "GSMLG.IpGeo.Download.run()"
      ./bin/gsmlg_umbrella eval "GSMLG.IpGeo.Download.run(:country)"

  Uses OTP's built-in `:httpc` so it works without any additional
  dependencies at runtime.

  ## Options

  The `opts` keyword list accepts:
    - `:force` - Overwrite existing database file (default: `false`)

  ## Configuration

  Database files are saved to the `priv/data/` directory of the
  `:gsmlg_ip_geo` application. Paths can be overridden via config:

      config :gsmlg_ip_geo,
        databases: %{
          city: "/custom/path/city.mmdb",
          country: "/custom/path/country.mmdb"
        }
  """

  require Logger

  @db_ip_base_url ~c"https://download.db-ip.com/free"

  @doc """
  Downloads both the city and country databases.

  ## Examples

      GSMLG.IpGeo.Download.run()
      GSMLG.IpGeo.Download.run(force: true)
  """
  @spec run(keyword()) :: :ok
  def run(opts \\ []) do
    load_app()
    start_http()

    for type <- [:city, :country] do
      case download(type, opts) do
        :ok -> :ok
        {:error, reason} -> Logger.error("[GSMLG.IpGeo.Download] Failed", type: type, error: inspect(reason))
      end
    end

    :ok
  end

  @doc """
  Downloads a single database by type (`:city` or `:country`).

  ## Examples

      GSMLG.IpGeo.Download.run(:city)
      GSMLG.IpGeo.Download.run(:country, force: true)
  """
  @spec run(atom(), keyword()) :: :ok | {:error, term()}
  def run(type, opts) when is_atom(type) do
    load_app()
    start_http()
    download(type, opts)
  end

  # Private

  defp download(type, opts) do
    target_path = resolve_path(type)

    if File.exists?(target_path) and !opts[:force] do
      Logger.info("[GSMLG.IpGeo.Download] Database already exists, skipping", path: target_path)
      Logger.info("[GSMLG.IpGeo.Download] Use force: true to overwrite")
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

    case :httpc.request(:get, {url, []}, [ssl: ssl_opts()], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        decompress_and_save(body, target_path)

      {:ok, {{_, status, _}, _headers, _body}} ->
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

  defp start_http do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp load_app do
    Application.load(:gsmlg_ip_geo)
  end
end
