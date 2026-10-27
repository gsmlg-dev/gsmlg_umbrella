defmodule GSMLG.AdminWeb.Components.AdminNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.Components.AdminNavigation

  describe "local_app_bar/1" do
    test "omits the quick-page menu when no navigation slot is supplied" do
      html = render_component(&GSMLG.Component.Admin.local_app_bar/1, page_title: "Home")
      document = Floki.parse_fragment!(html)

      assert Floki.find(document, "#admin-app-menu") == []
      assert Floki.find(document, "#admin-app-menu-popover") == []
      assert Floki.find(document, ~s(button[commandfor="admin-app-menu-popover"])) == []
      assert Floki.find(document, ~s(a[href="/users"])) == []
      assert Floki.find(document, ~s(a[href="/commander/list"])) == []
      assert Floki.find(document, ~s(a[href="/caddy"])) == []
    end

    test "keeps theme and sign-out controls without an appbar menu" do
      html = render_component(&GSMLG.Component.Admin.local_app_bar/1, page_title: "Home")
      document = Floki.parse_fragment!(html)

      assert Floki.find(document, ~s(button[aria-label="Toggle mobile menu"])) == []
      assert Floki.find(document, "#appbar-mobile-menu") == []
      assert [_theme_switcher] = Floki.find(document, ~s([phx-hook="ThemeSwitcher"]))

      assert [sign_out] =
               Floki.find(document, ~s(a[href="/sign_out"][data-admin-sign-out="true"]))

      assert Floki.text(sign_out) =~ "Sign Out"
    end
  end

  describe "left_menu/1" do
    test "provides a persistent collapse control and named icon links" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "gao_note_list")
      document = Floki.parse_fragment!(html)

      assert [navigation] =
               Floki.find(document, ~s(#admin-sidebar[phx-hook="DuskmoonLeftMenu"]))

      assert Floki.attribute(navigation, "data-storage-key") == ["gsmlg:admin-sidebar-collapsed"]

      assert [_toggle] =
               Floki.find(
                 navigation,
                 ~s(button[data-left-menu-toggle][aria-controls="admin-sidebar-scroll"][aria-expanded="true"])
               )

      for item <- GSMLG.AdminWeb.AdminMenu.enabled_items() do
        assert [link] = Floki.find(navigation, ~s(a[href="#{item.path}"]))
        assert Floki.attribute(link, "aria-label") == [item.label]
        assert [_icon] = Floki.find(link, "svg")
        assert [_label] = Floki.find(link, "[data-left-menu-label]")
        assert [_hint] = Floki.attribute(link, "data-left-menu-tooltip")
      end
    end

    test "renders the active branch and current page state" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "caddy_dashboard")

      assert html =~ ~s(aria-label="Admin navigation")
      assert html =~ "Caddy"
      assert html =~ "Dashboard"
      assert html =~ ~s(data-menu-group="caddy")
      assert html =~ ~r/<details(?=[^>]*data-menu-group="caddy")(?=[^>]*open)/
      refute html =~ ~r/<details(?=[^>]*data-menu-group="aws")(?=[^>]*open)/
      assert html =~ ~s(aria-current="page")
    end

    test "does not render the removed PKI module" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: nil)

      refute html =~ "PKI"
      refute html =~ ~s(data-menu-group="pki")
      refute html =~ ~s(href="/pki/ca")
      refute html =~ ~s(href="/pki/certificates")
      refute html =~ ~s(href="/pki/csr")
      refute html =~ ~s(href="/pki/search")
      refute html =~ ~s(href="/pki/analytics")
    end

    test "renders disabled placeholders without navigation targets" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "dynamo_db")

      assert html =~ "Lightsail: Instance"
      assert html =~ ~s(aria-disabled="true")
      refute html =~ ~s(href="/aws/lightsail")
    end

    test "renders GaoNote in the content navigation group" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "gao_note_list")

      assert html =~ "Content"
      assert html =~ "GaoNote"
      assert html =~ "Dashboard"
      assert html =~ "Note List"
      refute html =~ "New Note"
      assert html =~ "Label Settings"
      assert html =~ "Recycle Bin"
      assert html =~ "Log"
      assert html =~ "MCP"
      assert html =~ ~s(href="/gao_notes")
      assert html =~ ~s(href="/gao_notes/notes")
      refute html =~ ~s(href="/gao_notes/notes/new")
      assert html =~ ~s(href="/gao_notes/label_settings")
      assert html =~ ~s(href="/gao_notes/recycle_bin")
      assert html =~ ~s(href="/gao_notes/logs")
      assert html =~ ~s(href="/gao_notes/mcp")
      refute html =~ "Note Attachments"
      refute html =~ "Note References"
      refute html =~ "Note Assets"
      refute html =~ ~s(href="/gao_notes/attachments")
      refute html =~ ~s(href="/gao_notes/references")
      refute html =~ ~s(href="/gao_notes/assets")
      assert html =~ ~r/<details(?=[^>]*data-menu-group="gao_notes")(?=[^>]*open)/
    end

    test "renders Proxy Rules as the active service branch" do
      html =
        render_component(&AdminNavigation.left_menu/1,
          active_menu: "proxy_rules_dashboard"
        )

      assert html =~ "Proxy Rules"
      assert html =~ ~s(href="/proxy-rules")
      assert html =~ ~r/<details(?=[^>]*data-menu-group="proxy_rules")(?=[^>]*open)/
      assert html =~ ~s(aria-current="page")
    end
  end

  describe "Layouts.app/1" do
    test "keeps mobile navigation expanded with separate component ids" do
      html =
        render_component(&GSMLG.AdminWeb.Layouts.app/1,
          flash: %{},
          active_menu: "gao_note_list",
          inner_block: [
            %{
              __slot__: :inner_block,
              inner_block: fn _, _ -> "PAGE BODY" end
            }
          ]
        )

      document = Floki.parse_fragment!(html)
      assert [desktop] = Floki.find(document, "#admin-sidebar")
      assert [_toggle] = Floki.find(desktop, "[data-left-menu-toggle]")
      assert [mobile] = Floki.find(document, "#admin-mobile-menu")
      assert Floki.find(mobile, "[data-left-menu-toggle]") == []
      assert Floki.attribute(mobile, "data-storage-key") == []
      assert [_notes] = Floki.find(mobile, ~s(a[href="/gao_notes/notes"][aria-current="page"]))

      ids = Floki.find(document, "[id]") |> Enum.flat_map(&Floki.attribute(&1, "id"))
      assert Enum.uniq(ids) == ids
    end

    test "keeps Storage navigation available in the appbar menu" do
      html =
        render_component(&GSMLG.AdminWeb.Layouts.app/1,
          flash: %{},
          page_title: "Storage",
          active_menu: "storage_files",
          inner_block: [
            %{
              __slot__: :inner_block,
              inner_block: fn _, _ -> "PAGE BODY" end
            }
          ]
        )

      document = Floki.parse_fragment!(html)
      assert [popover] = Floki.find(document, "#admin-app-menu-popover")
      assert [_files] = Floki.find(popover, ~s(a[href="/storage"][aria-current="page"]))
      assert [_config] = Floki.find(popover, ~s(a[href="/storage/config"]))
    end

    test "renders the global navigation and page body" do
      html =
        render_component(&GSMLG.AdminWeb.Layouts.app/1,
          flash: %{},
          page_title: "Users",
          active_menu: "user_list",
          inner_block: [
            %{
              __slot__: :inner_block,
              inner_block: fn _, _ -> "PAGE BODY" end
            }
          ]
        )

      assert html =~ "PAGE BODY"
      assert html =~ ~s(aria-label="Admin navigation")
      assert html =~ ~r/<details(?=[^>]*data-menu-group="users")(?=[^>]*open)/
    end
  end
end
