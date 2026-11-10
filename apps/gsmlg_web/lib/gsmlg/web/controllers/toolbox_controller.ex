defmodule GSMLG.Web.ToolboxController do
  use GSMLG.Web, :controller

  # Keep Phoenix route verification and the existing browser/session/locale
  # pipeline while rendering the complete document through Hologram's plug.
  def hologram(conn, _params) do
    conn = Hologram.Router.call(conn, Hologram.Router.init([]))
    if conn.halted, do: conn, else: send_resp(conn, :service_unavailable, "Service unavailable")
  end

  def ip_geo_json(conn, _params), do: service_unavailable(conn)
  def whois_json(conn, _params), do: service_unavailable(conn)
  def rdap_json(conn, _params), do: service_unavailable(conn)

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

    {:error, error} = GSMLG.SVG2React.convert(data)
    conn |> put_status(:service_unavailable) |> json(%{error: error})
  end

  def mac_manufacturer_json(conn, _params), do: service_unavailable(conn)
  def ip_to_geomap_post(conn, _params), do: service_unavailable(conn)

  defp service_unavailable(conn) do
    conn
    |> put_status(:service_unavailable)
    |> json(%{
      error: "service_unavailable",
      message: GSMLG.Web.Hologram.Messages.service_unavailable()
    })
  end
end
