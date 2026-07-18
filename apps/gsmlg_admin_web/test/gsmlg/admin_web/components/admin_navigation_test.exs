defmodule GSMLG.AdminWeb.Components.AdminNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.Components.AdminNavigation

  describe "left_menu/1" do
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
      assert html =~ "Note List"
      refute html =~ "New Note"
      assert html =~ "Label Settings"
      assert html =~ "Recycle Bin"
      assert html =~ "Log"
      assert html =~ "MCP"
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
  end

  describe "Layouts.app/1" do
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
