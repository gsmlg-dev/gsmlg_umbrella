defmodule GSMLG.AdminWeb.Guardian.WebAuthErrorHandlerTest do
  use GSMLG.AdminWeb.ConnCase, async: true

  alias GSMLG.AdminWeb.Guardian.WebAuthErrorHandler

  test "redirects when Guardian reports an exception reason", %{conn: conn} do
    reason = RuntimeError.exception("repo unavailable")

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> Phoenix.Controller.fetch_flash()
      |> WebAuthErrorHandler.auth_error({:invalid_token, reason}, [])

    assert redirected_to(conn) == ~p"/sign_in"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) == "invalid_token: repo unavailable"
  end
end
