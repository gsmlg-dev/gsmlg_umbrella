defmodule GSMLGWeb.ToolboxController do
  use GSMLGWeb, :tool_controller
  use Phoenix.Component

  @asn_regex ~r/^[0-9]{1,10}$/
  @ipv4_regex ~r/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
  @ipv6_regex ~r/^(?:[A-F0-9]{1,4}:){7}[A-F0-9]{1,4}$/

  def index(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        Toolbox
      </h1>
    </div>
    """

    tools = []
    render(conn, :index, tools: tools, header_slot: header_slot)
  end

  def geoip2(conn, params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        GeoIP2
      </h1>
    </div>
    """

    lang = Map.get(params, "lang", "en")

    render(conn, :geoip2, ipInfo: nil, ip: nil, lang: lang, langs: GSMLG.GeoIP2.langs(), header_slot: header_slot)
  end

  def geoip2_find(conn, %{"ip" => ip} = params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        GeoIP2
      </h1>
    </div>
    """

    lang = Map.get(params, "lang")

    ipInfo = GSMLG.GeoIP2.get_ip_info(ip, lang)

    render(conn, :geoip2, ipInfo: ipInfo, ip: ip, lang: lang, langs: GSMLG.GeoIP2.langs(), header_slot: header_slot)
  end

  def whois(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        Whois
      </h1>
    </div>
    """

    render(conn, :whois, whois_info: nil, header_slot: header_slot)
  end

  def whois_find(conn, %{"look_for" => look_for} = _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        Whois
      </h1>
    </div>
    """

    cond do
      Regex.match?(@asn_regex, look_for) ->
        case GSMLG.Whois.lookup_as_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois,
              whois_info: info,
              reason: nil,
              look_for: look_for,
              header_slot: header_slot
            )

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason, header_slot: header_slot)
        end

      Regex.match?(@ipv4_regex, look_for) or Regex.match?(@ipv6_regex, look_for) ->
        case GSMLG.Whois.lookup_ip_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois, whois_info: info, reason: nil, header_slot: header_slot)

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason, header_slot: header_slot)
        end

      true ->
        case GSMLG.Whois.lookup_domain_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois, whois_info: info, reason: nil, header_slot: header_slot)

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason, header_slot: header_slot)
        end
    end
  end

  def svg2react(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        SVG to React
      </h1>
    </div>
    """

    render(conn, :svg2react, header_slot: header_slot)
  end

  def svg2react_convert(conn, %{"code" => code, "options" => options} = _params) do
    data = %{
      "code" => code,
      "options" => %{
        "icon" => true,
        "native" => Map.get(options, "native", false),
        "typescript" => false,
        "ref" => Map.get(options, "ref", true),
        "memo" => false,
        "titleProp" => false,
        "descProp" => false,
        "expandProps" => "end",
        "replaceAttrValues" => %{},
        "svgProps" => %{},
        "svgo" => true,
        "svgoConfig" => %{
          "plugins" => [
            %{
              "name" => "preset-default",
              "params" => %{
                "overrides" => %{
                  "removeTitle" => false
                }
              }
            }
          ]
        },
        "prettier" => true,
        "prettierConfig" => %{"semi" => false}
      }
    }

    case GSMLG.SVG2React.convert(data) do
      {:ok, result} ->
        conn |> json(%{data: result})

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: error})
    end
  end

  def svg_autocrop(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        SVG Autocrop
      </h1>
    </div>
    """

    render(conn, :svg_autocrop, header_slot: header_slot)
  end

  def svg_autocrop_convert(conn, %{"code" => code} = _params) do
    case GSMLG.SVG_Autocrop.convert(%{"code" => code}) do
      {:ok, result} ->
        conn |> json(%{data: result})

      {:error, error} ->
        conn |> put_status(422) |> json(%{error: error})
    end
  end

  def mac_manufacturer(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        MAC Manufacturer
      </h1>
    </div>
    """

    render(conn, :mac_manufacturer, header_slot: header_slot)
  end

  def mac_manufacturer_lookup(conn, %{"mac" => mac} = _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        MAC Manufacturer
      </h1>
    </div>
    """

    case GSMLG.MAC.lookup_vendor(mac) do
      {:ok, short, full} ->
        render(conn, :mac_manufacturer, short: short, full: full, header_slot: header_slot)

      :error ->
        render(conn, :mac_manufacturer, short: "Unkown", header_slot: header_slot)
    end
  end

  def ip_to_geomap(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="container flex justify-center items-center my-24">
      <h1 class="w-48 h-24 flex justify-center items-center text-8xl font-bold whitespace-nowrap">
        IP to GeoMap
      </h1>
    </div>
    """

    render(conn, :ip_to_geomap, header_slot: header_slot)
  end

  def ip_to_geomap_post(conn, %{"ip" => ip}) do
    ipInfo = GSMLG.GeoIP2.get_ip_info(ip)
    conn |> json(%{data: ipInfo})
  end
end
