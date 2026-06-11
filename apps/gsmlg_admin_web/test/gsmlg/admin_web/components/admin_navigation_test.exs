defmodule GSMLG.AdminWeb.Components.AdminNavigationTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.Components.AdminNavigation

  describe "left_menu/1" do
    test "renders the active branch and current page state" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "pki_ca_list")

      assert html =~ ~s(aria-label="Admin navigation")
      assert html =~ "PKI"
      assert html =~ "CA List"
      assert html =~ ~s(data-menu-group="pki")
      assert html =~ ~r/<details(?=[^>]*data-menu-group="pki")(?=[^>]*open)/
      refute html =~ ~r/<details(?=[^>]*data-menu-group="aws")(?=[^>]*open)/
      assert html =~ ~s(aria-current="page")
    end

    test "renders disabled placeholders without navigation targets" do
      html = render_component(&AdminNavigation.left_menu/1, active_menu: "dynamo_db")

      assert html =~ "Lightsail: Instance"
      assert html =~ ~s(aria-disabled="true")
      refute html =~ ~s(href="/aws/lightsail")
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
