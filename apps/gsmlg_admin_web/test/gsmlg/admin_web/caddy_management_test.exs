defmodule GSMLG.AdminWeb.CaddyManagementTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.{PageController, PageHTML, Router}

  @management_paths [
    "/caddy",
    "/caddy/config",
    "/caddy/server",
    "/caddy/server/settings",
    "/caddy/metrics",
    "/caddy/runtime",
    "/caddy/logs",
    "/caddy/unknown/nested"
  ]

  test "Caddy management URLs use the disabled controller instead of mounting LiveViews" do
    for path <- @management_paths do
      assert %{plug: PageController, plug_opts: :caddy_disabled} =
               Phoenix.Router.route_info(Router, "GET", path, "localhost")
    end
  end

  test "disabled Caddy management returns not found" do
    for path <- @management_paths do
      conn =
        Plug.Test.conn("GET", path)
        |> PageController.call(:caddy_disabled)

      assert conn.status == 404
      assert conn.resp_body == "Not Found"
      assert conn.state == :sent
    end
  end

  test "admin home does not render Caddy management links or cards" do
    html =
      render_component(&PageHTML.index/1,
        flash: %{},
        page_title: "Home",
        data: %{blog_count: 0, user_count: 0, token_count: 0}
      )

    document = Floki.parse_fragment!(html)

    refute html =~ "Caddy"
    assert Floki.find(document, ~s(a[href^="/caddy"])) == []
    assert Floki.find(document, ~s(a[href="/commander/list"])) != []
  end
end
