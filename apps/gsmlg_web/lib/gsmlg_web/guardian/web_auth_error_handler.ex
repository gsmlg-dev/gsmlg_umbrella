defmodule GSMLGWeb.Guardian.WebAuthErrorHandler do
  import Plug.Conn
  use GSMLGWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    conn
    |> put_flash(:error, "#{type}: #{reason}")
    |> redirect(to: Routes.auth_path(conn, :index))
  end
end
