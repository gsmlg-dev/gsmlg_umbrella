defmodule GSMLGWeb.ToolboxController do
  use GSMLGWeb, :tool_controller

  @asn_regex ~r/^[0-9]{1,10}$/
  @ipv4_regex ~r/^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/
  @ipv6_regex ~r/^(?:[A-F0-9]{1,4}:){7}[A-F0-9]{1,4}$/

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
    render(conn, :whois, whois_info: nil)
  end

  def whois_find(conn, %{"look_for" => look_for} = _params) do
    cond do
      Regex.match?(@asn_regex, look_for) ->
        case GSMLG.Whois.lookup_as_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois, whois_info: info, reason: nil)

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason)
        end

      Regex.match?(@ipv4_regex, look_for) or Regex.match?(@ipv6_regex, look_for) ->
        case GSMLG.Whois.lookup_ip_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois, whois_info: info, reason: nil)

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason)
        end

      true ->
        case GSMLG.Whois.lookup_raw(look_for) do
          {:ok, info} ->
            render(conn, :whois, whois_info: info, reason: nil)

          {:error, reason} ->
            render(conn, :whois, whois_info: :error, reason: reason)
        end
    end
  end

  def svg2react(conn, _params) do
    render(conn, :svg2react)
  end

  def svg2react_convert(conn, params) do
    IO.inspect(params)
    %{"code" => code} = params

    data = %{
      "code" => code,
      "options" => %{
        "icon" => true,
        "native" => false,
        "typescript" => false,
        "ref" => true,
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
end
