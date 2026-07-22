defmodule GSMLG.AdminWeb.ProxyRulesLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  @secret_key_base String.duplicate("p", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    authenticated_conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(
        GSMLG.AdminWeb.Guardian,
        user,
        %{},
        token_type: "access"
      )
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{
      conn: authenticated_conn,
      unauthenticated_conn: Phoenix.ConnTest.build_conn() |> with_secret_key_base()
    }
  end

  test "redirects unauthenticated requests to sign in", %{unauthenticated_conn: conn} do
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/proxy-rules")
  end

  test "renders the explicit not-ready dashboard state", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/proxy-rules")

    assert html =~ "Proxy Rules"
    assert has_element?(view, "#proxy-rules-status", "Not ready")
    assert has_element?(view, "#proxy-rules-generation", "Not available")
    assert has_element?(view, "#proxy-rules-compiled-at", "Not available")
    assert has_element?(view, "#proxy-rules-proxy-count", "Not available")
    assert has_element?(view, "#proxy-rules-direct-count", "Not available")
    assert has_element?(view, "#proxy-rules-source-remote-gfwlist", "Not available")
    assert has_element?(view, "#proxy-rules-source-local-proxy-list", "Not available")
    assert has_element?(view, "#proxy-rules-source-local-direct-list", "Not available")
    assert has_element?(view, "#proxy-rules-artifacts-empty", "No artifacts have been published.")
    refute has_element?(view, "#proxy-rules-artifacts a")
  end

  test "marks navigation active and keeps refresh unavailable", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/proxy-rules")

    assert has_element?(view, "details[data-menu-group='proxy_rules'][open]")
    assert has_element?(view, "a[href='/proxy-rules'][aria-current='page']", "Dashboard")
    assert has_element?(view, "#proxy-rules-refresh[disabled][aria-disabled='true']")
    refute has_element?(view, "#proxy-rules-refresh[phx-click]")
  end

  defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
