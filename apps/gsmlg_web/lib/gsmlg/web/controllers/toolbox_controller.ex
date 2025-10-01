defmodule GSMLG.Web.ToolboxController do
  use GSMLG.Web, :controller
  use Phoenix.Component

  def index(conn, _params) do
    tools = []
    render(conn, :index, tools: tools, title: "Toolbox")
  end

  def geoip2(conn, params) do
    lang = Map.get(params, "lang", "en")

    render(conn, :geoip2,
      ipInfo: nil,
      ip: nil,
      lang: lang,
      langs: GSMLG.GeoIP2.langs(),
      title: "GeoIP2"
    )
  end

  def geoip2_find(conn, %{"ip" => ip} = params) do
    lang = Map.get(params, "lang", "en")
    ipInfo = GSMLG.GeoIP2.get_ip_info(ip, lang)

    render(conn, :geoip2,
      ipInfo: ipInfo,
      ip: ip,
      lang: lang,
      langs: GSMLG.GeoIP2.langs(),
      title: "GeoIP2"
    )
  end

  def whois(conn, _params) do
    render(conn, :whois, look_for: nil, whois_info: nil, title: "Whois")
  end

  def whois_find(conn, %{"look_for" => look_for} = _params) do
    case GSMLG.Whois.lookup_raw(look_for) do
      {:ok, whois_info} ->
        render(conn, :whois,
          look_for: look_for,
          whois_info: Enum.reverse(whois_info),
          reason: nil,
          title: "Whois"
        )

      {:error, reason} ->
        render(conn, :whois,
          look_for: look_for,
          whois_info: :error,
          reason: reason,
          title: "Whois"
        )
    end
  end

  def svg2react(conn, _params) do
    render(conn, :svg2react, title: "SVG to React")
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
    render(conn, :svg_autocrop, title: "SVG Autocrop")
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
    render(conn, :mac_manufacturer, title: "MAC Manufacturer")
  end

  def mac_manufacturer_lookup(conn, %{"mac" => mac} = _params) do
    case GSMLG.MAC.lookup_vendor(mac) do
      {:ok, short, full} ->
        render(conn, :mac_manufacturer,
          short: short,
          full: full,
          title: "MAC Manufacturer"
        )

      :error ->
        render(conn, :mac_manufacturer,
          short: "Unkown",
          title: "MAC Manufacturer"
        )
    end
  end

  def ip_to_geomap(conn, _params) do
    render(conn, :ip_to_geomap, title: "IP to GeoMap")
  end

  def ip_to_geomap_post(conn, %{"ip" => ip}) do
    ipInfo = GSMLG.GeoIP2.get_ip_info(ip)
    conn |> json(%{data: ipInfo})
  end

  def screensaver(conn, _params) do
    render(conn, :screensaver, title: "Screen Saver")
  end

  defp header_slot(title) do
    assigns = %{title: title}

    ~H"""
    <div class="header-hero-container @container">
      <h1 class="header-hero-text @xs:text-xl @md:text-2xl @xl:text-3xl @3xl:text-4xl @5xl:text-6xl @7xl:text-8xl">
        {@title}
      </h1>
    </div>
    """
  end
end
