defmodule GSMLGWeb.ToolboxController do
  use GSMLGWeb, :tool_controller

  def index(conn, _params) do
    tools = []
    render(conn, :index, tools: tools)
  end

  def geoip2(conn, _params) do
    render(conn, :geoip2, ipInfo: nil, langs: GSMLG.GeoIP2.langs())
  end

  def geoip2_find(conn, %{"ip" => ip} = params) do
    lang = Map.get(params, "lang")

    ipInfo = GSMLG.GeoIP2.get_ip_info(ip, lang)

    render(conn, :geoip2, ipInfo: ipInfo, langs: GSMLG.GeoIP2.langs())
  end

  def whois(conn, _params) do
    render(conn, :whois, domainInfo: nil)
  end

  def whois_find(conn, %{"domain" => domain} = params) do
    case GSMLG.Whois.lookup_raw(domain) do
      {:ok, info} ->
        render(conn, :whois, domainInfo: info, reason: nil)

      {:error, reason} ->
        render(conn, :whois, domainInfo: :error, reason: reason)
    end
  end
end
