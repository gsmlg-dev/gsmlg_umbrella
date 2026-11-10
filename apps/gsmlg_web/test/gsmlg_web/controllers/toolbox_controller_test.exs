defmodule GSMLG.Web.ToolboxControllerTest do
  use GSMLG.Web.ConnCase, async: false

  test "lists all tools", %{conn: conn} do
    conn = get(conn, ~p"/toolbox?lang=en")
    assert html_response(conn, 200) =~ "Toolbox"
  end

  test "lookup pages retain their UI with disabled controls and a localized notice", %{conn: conn} do
    for {locale, message} <- [
          {"en", "Service temporarily unavailable."},
          {"zh-Hans", "服务暂时不可用。"}
        ],
        {path, form, input, button, result} <- [
          {"/toolbox/ip_geo", "#ip-geo-form", "#ip-input", "#ip-submit", "#ip-result"},
          {"/toolbox/whois", "#whois-form", "#whois-input", "#whois-submit", "#whois-result"},
          {"/toolbox/mac_manufacturer", "#mac-form", "#mac-input", "#mac-submit", "#mac-result"},
          {"/toolbox/ip_to_geomap", "form", "#ip-data", "#submit-ip", "#ip-geo-map"}
        ] do
      document =
        conn |> get(path, lang: locale) |> html_response(200) |> Floki.parse_document!()

      assert Floki.find(document, "main [role=status]") |> Floki.text() == message
      assert [_form] = Floki.find(document, "main " <> form)
      assert [_input] = Floki.find(document, input <> "[disabled]")
      assert [_button] = Floki.find(document, button <> "[type=submit][disabled]")
      assert [_result] = Floki.find(document, result)

      if path in ["/toolbox/ip_geo", "/toolbox/ip_to_geomap"] do
        assert [_map] = Floki.find(document, "d3-world-map#ip-geo-map")
      end

      if path == "/toolbox/whois" do
        assert [_protocols] = Floki.find(document, "#whois-form fieldset[disabled]")
      end
    end
  end

  test "lookup APIs return 503 for valid, missing and malformed parameters", %{conn: conn} do
    Gettext.with_locale(GSMLG.Web.Gettext, "en", fn ->
      for {path, params} <- [
            {"/api/toolbox/ip_geo", %{ip: "8.8.8.8"}},
            {"/api/toolbox/whois", %{look_for: "example.com"}},
            {"/api/toolbox/whois/rdap", %{look_for: "example.com", type: "domain"}},
            {"/api/toolbox/mac_manufacturer", %{mac: "00:00:0A:BB:28:FC"}},
            {"/api/toolbox/ip_to_geomap", %{ip: "8.8.8.8"}}
          ],
          input <- [
            params,
            %{},
            %{ip: %{bad: "input"}, mac: %{bad: "input"}, look_for: %{bad: "input"}}
          ] do
        assert conn |> get(path, input) |> json_response(503) == %{
                 "error" => "service_unavailable",
                 "message" => "Service temporarily unavailable."
               }
      end
    end)
  end
end
