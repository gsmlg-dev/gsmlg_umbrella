defmodule GSMLG.AdminWeb.BrowserAPI.ErrorController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.AdminWeb.BrowserAPI.Response

  def not_found(conn, _params) do
    Response.error(conn, 404, "request", "not_found", "Browser API route not found.", false, nil)
  end
end
