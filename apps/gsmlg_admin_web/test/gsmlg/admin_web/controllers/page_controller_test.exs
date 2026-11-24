defmodule GSMLG.AdminWeb.PageControllerTest do
  use GSMLG.AdminWeb.ConnCase

  import GSMLG.AccountsFixtures

  # default action will rederect to sign_in
  test "GET /", %{conn: conn} do
    conn = get(conn, "/")
    assert html_response(conn, 302) =~ "sign_in"
  end

  test "the embedded dashboard and its iframe require an admin session", %{conn: conn} do
    for path <- [~p"/dashboard", ~p"/live_dashboard", ~p"/live_dashboard/home"] do
      assert conn |> get(path) |> redirected_to() == ~p"/sign_in"
    end
  end

  test "the home card and sidebar open the dashboard inside the admin shell", %{conn: conn} do
    user = user_fixture()

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")

    home = conn |> get(~p"/") |> html_response(200) |> Floki.parse_document!()
    assert Floki.text(Floki.find(home, ~s(main a[href="/dashboard"]))) =~ "Live Dashboard"

    page = conn |> get(~p"/dashboard") |> html_response(200) |> Floki.parse_document!()

    active_dashboard = ~s(nav a[href="/dashboard"][aria-current="page"])
    assert Floki.text(Floki.find(page, active_dashboard)) =~ "Live Dashboard"
    assert Floki.attribute(page, "main iframe", "src") == [~p"/live_dashboard/home"]
    assert Floki.attribute(page, "main iframe", "title") == ["Live Dashboard"]

    dashboard = get(conn, ~p"/live_dashboard/home")
    assert html_response(dashboard, 200) =~ "Phoenix LiveDashboard"
    assert [policy] = get_resp_header(dashboard, "content-security-policy")
    assert policy =~ "frame-ancestors 'self'"
  end
end
