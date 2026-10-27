defmodule GSMLG.Web.Hologram.LayoutTest do
  use GSMLG.Web.ConnCase, async: false

  alias GSMLG.Web.Hologram.LayoutDOM

  test "every tool keeps the shared appbar, hero, mobile menus and footer", %{conn: conn} do
    for {path, title} <- [
          {"/toolbox", "Toolbox"},
          {"/toolbox/ip_geo", "IP Geo"},
          {"/toolbox/whois", "Whois"},
          {"/toolbox/mac_manufacturer", "MAC Manufacturer"},
          {"/toolbox/svg2react", "SVG to React"},
          {"/toolbox/svg_autocrop", "SVG Autocrop"},
          {"/toolbox/ip_to_geomap", "IP to GeoMap"},
          {"/toolbox/screensaver", "Screen Saver"}
        ] do
      document = conn |> get(path <> "?lang=en") |> html_response(200) |> Floki.parse_document!()

      assert [_header] = Floki.find(document, "header#wc-page-header-header")
      assert [_fixed_nav] = Floki.find(document, "nav#wc-page-header-nav.fixed")
      assert [_hero] = Floki.find(document, "#wc-page-header-header h1.header-hero-text")
      assert document |> Floki.find("header h1") |> Floki.text() |> String.trim() == title
      assert [_mobile] = Floki.find(document, "input#dm-mobile-menu-control[type=checkbox]")
      assert [_fixed_mobile] = Floki.find(document, "input#mobile-menu[type=checkbox]")
      assert [_snow] = Floki.find(document, "#snow-bg")
      assert Floki.find(document, "[phx-hook=ThemeSwitcher]") != []
      assert Floki.find(document, "header svg path") != []
      assert Floki.find(document, "main h1") == []
      assert [_sign_in] = Floki.find(document, "footer a[href='/sign_in']")
      assert [_tool_link] = Floki.find(document, "footer a[href='/toolbox/ip_geo']")
      assert [_language] = Floki.find(document, "footer a[href='?lang=en'][aria-current=true]")
      assert [_stylesheet] = Floki.find(document, "link[rel=stylesheet][href^='/assets/css/app']")
      assert Floki.find(document, "script[src*='/assets/js/app']") == []
    end
  end

  test "the catalogue restores its introduction and seven-tool count", %{conn: conn} do
    document = conn |> get("/toolbox?lang=en") |> html_response(200) |> Floki.parse_document!()

    assert document |> Floki.find("header") |> Floki.text() =~ "Developer Utilities"
    assert document |> Floki.find("header") |> Floki.text() =~ "7 tools available"
    assert length(Floki.find(document, "main article")) == 7
  end

  test "shared layout follows the locale resolved by the browser pipeline", %{conn: conn} do
    response = get(conn, "/toolbox?lang=zh-CN")
    document = response |> html_response(200) |> Floki.parse_document!()

    assert get_session(response, "locale") == "zh-Hans"
    assert [_html] = Floki.find(document, "html[lang=zh-Hans]")

    assert [_language] =
             Floki.find(document, "footer a[href='?lang=zh-Hans'][aria-current=true]")

    assert document |> Floki.find("header") |> Floki.text() =~ "工具箱"
  end

  test "trusted HEEx conversion preserves attributes, entities, SVG names and the page slot" do
    rendered =
      Phoenix.HTML.raw(
        """
        <section data-label="A &amp; &quot;B&quot;"><svg viewBox="0 0 10 10"><path d="M0 0h10v10Z" /></svg><span>&lt;tools&gt; &amp; more</span><slot></slot><input disabled><script>window.layoutScript = true</script></section>
        """
        |> String.trim()
      )

    assert [
             {:element, "section", [{"data-label", [text: "A & \"B\""]}],
              [
                {:element, "svg", [{"viewBox", [text: "0 0 10 10"]}],
                 [
                   {:element, "path", [{"d", [text: "M0 0h10v10Z"]}], []}
                 ]},
                {:element, "span", [], [{:text, "<tools> & more"}]},
                {:element, "slot", [], []},
                {:element, "input", [{"disabled", [text: "disabled"]}], []}
              ]}
           ] = LayoutDOM.from_rendered(rendered)
  end
end
