defmodule GSMLG.Web.ToolboxController do
  use GSMLG.Web, :controller

  # Keep Phoenix route verification and the existing browser/session/locale
  # pipeline while rendering the complete document through Hologram's plug.
  def hologram(conn, _params) do
    conn = Hologram.Router.call(conn, Hologram.Router.init([]))
    if conn.halted, do: conn, else: send_resp(conn, :service_unavailable, "Service unavailable")
  end

  def ip_geo_json(conn, %{"ip" => ip}) do
    case GSMLG.IpGeo.lookup(ip) do
      {:ok, info} -> conn |> json(%{data: info})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: reason})
    end
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

  def rdap_json(conn, %{"look_for" => look_for} = params) do
    type =
      case Map.get(params, "type", "domain") do
        "ip" -> :ip
        "asn" -> :asn
        _ -> :domain
      end

    case GSMLG.Whois.rdap_lookup(look_for, type: type) do
      {:ok, data} -> conn |> json(%{data: data})
      {:error, reason} -> conn |> put_status(422) |> json(%{error: inspect(reason)})
    end
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

  def mac_manufacturer_json(conn, %{"mac" => mac}) do
    case GSMLG.MAC.lookup_vendor(mac) do
      {:ok, short, full} -> conn |> json(%{data: %{short: short, full: full}})
      :error -> conn |> put_status(404) |> json(%{error: "Unknown"})
    end
  end

  def ip_to_geomap_post(conn, %{"ip" => ip}) do
    ipInfo =
      case GSMLG.IpGeo.lookup(ip) do
        {:ok, info} -> info
        {:error, _} -> %{}
      end

    conn |> json(%{data: ipInfo})
  end
end
