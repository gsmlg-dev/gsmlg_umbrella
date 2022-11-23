defmodule GSMLGWeb.ToolboxController do
  use GSMLGWeb, :controller

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
end
