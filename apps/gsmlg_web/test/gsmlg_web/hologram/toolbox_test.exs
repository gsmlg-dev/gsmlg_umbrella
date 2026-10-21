defmodule GSMLG.Web.Hologram.ToolboxTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Web.Hologram.Pages.{IpToGeomap, SvgAutocrop}
  alias Hologram.{Component, Server}

  test "all toolbox GET routes render Hologram and keep browser headers", %{conn: conn} do
    for path <-
          ~w(/toolbox /toolbox/ip_geo /toolbox/whois /toolbox/mac_manufacturer /toolbox/svg2react /toolbox/svg_autocrop /toolbox/ip_to_geomap /toolbox/screensaver) do
      response = get(conn, path <> "?lang=en")
      html = html_response(response, 200)
      assert html =~ "Hologram.pageMountData"
      assert html =~ "/hologram/runtime"
      assert html =~ "Toolbox"
      assert get_resp_header(response, "x-content-type-options") == ["nosniff"]
    end
  end

  test "toolbox resolves language through the existing locale plug", %{conn: conn} do
    response = get(conn, "/toolbox?lang=zh-CN")
    assert get_session(response, "locale") == "zh-Hans"
    assert html_response(response, 200) =~ ~s(lang="zh-Hans")

    response = conn |> put_req_header("accept-language", "en-US,en;q=0.9") |> get("/toolbox")
    assert html_response(response, 200) =~ ~s(lang="en")
  end

  test "legacy SVG conversion POST retains its JSON response", %{conn: conn} do
    response =
      post(conn, "/toolbox/svg2react", code: "<svg viewBox=\"0 0 10 10\" />", options: %{})

    assert %{"data" => code} = json_response(response, 200)
    assert code =~ "SvgIcon"
    assert code =~ "forwardRef"
  end

  test "legacy SVG POST and Hologram commands reject missing CSRF tokens", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/toolbox/svg2react", code: "<svg />", options: %{})
    end

    assert conn |> post("/hologram/command", %{}) |> response(403) == "Forbidden"
  end

  test "SVG cropping queues browser work with input held as text" do
    component = %Component{state: %{text: %{invalid_input: "Invalid input"}}}

    assert %{
             state: %{loading: true, source: "<svg />", output: "", error: nil},
             next_action: %{name: :crop}
           } =
             SvgAutocrop.action(:convert, %{event: %{"code" => "<svg />"}}, component)
  end

  test "map submission queues each address progressively" do
    component = %Component{state: %{text: %{invalid_input: "Invalid input"}}}

    assert %{
             state: %{loading: true, remaining: ["8.8.8.8"], points: []},
             next_command: %{name: :lookup, params: %{ip: "1.1.1.1"}}
           } =
             IpToGeomap.action(:lookup, %{event: %{"ips" => " 1.1.1.1\n8.8.8.8 "}}, component)

    assert %{next_action: %{name: :located, params: %{point: nil}}} =
             IpToGeomap.command(:lookup, %{ip: %{}}, %Server{})
  end
end
