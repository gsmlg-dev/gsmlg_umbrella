defmodule GSMLG.Web.ToolboxController do
  use GSMLG.Web, :controller
  use Phoenix.Component

  def index(conn, _params) do
    tools = []
    render(conn, :index, tools: tools, title: dgettext("toolbox", "Toolbox"))
  end

  def ip_geo(conn, _params) do
    render(conn, :ip_geo, title: dgettext("toolbox", "IP Geo"))
  end

  def ip_geo_json(conn, %{"ip" => ip}) do
    case GSMLG.IpGeo.lookup(ip) do
      {:ok, info} -> conn |> json(%{data: info})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
  end

  def whois(conn, _params) do
    render(conn, :whois, title: dgettext("toolbox", "Whois"))
  end

  def whois_json(conn, %{"look_for" => look_for}) do
    case GSMLG.Whois.lookup_raw(look_for) do
      {:ok, whois_info} ->
        data = whois_info |> Enum.reverse() |> Enum.map(fn {server, info} -> [server, info] end)
        conn |> json(%{data: data})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
  end

  def svg2react(conn, _params) do
    render(conn, :svg2react, title: dgettext("toolbox", "SVG to React"))
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
    render(conn, :svg_autocrop, title: dgettext("toolbox", "SVG Autocrop"))
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
    render(conn, :mac_manufacturer, title: dgettext("toolbox", "MAC Manufacturer"))
  end

  def mac_manufacturer_json(conn, %{"mac" => mac}) do
    case GSMLG.MAC.lookup_vendor(mac) do
      {:ok, short, full} -> conn |> json(%{data: %{short: short, full: full}})
      :error -> conn |> put_status(404) |> json(%{error: "Unknown"})
    end
  end

  def ip_to_geomap(conn, _params) do
    render(conn, :ip_to_geomap, title: dgettext("toolbox", "IP to GeoMap"))
  end

  def ip_to_geomap_post(conn, %{"ip" => ip}) do
    ipInfo =
      case GSMLG.IpGeo.lookup(ip) do
        {:ok, info} -> info
        {:error, _} -> %{}
      end

    conn |> json(%{data: ipInfo})
  end

  def screensaver(conn, _params) do
    render(conn, :screensaver, title: dgettext("toolbox", "Screen Saver"))
  end
end
