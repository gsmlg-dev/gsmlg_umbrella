defmodule GSMLG.Web.ApiErrorController do
  use GSMLG.Web, :controller

  def not_found(conn, _params) do
    conn
    |> put_status(:not_found)
    |> put_view(json: GSMLG.Web.ErrorJSON)
    |> render(:"404")
  end
end
