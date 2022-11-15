defmodule GSMLGAdminWeb.Guardian.WebAuthErrorHandler do
  import Plug.Conn
  use GSMLGAdminWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    IO.puts("[WebAuthErrorHandler] #{type}: #{reason}")

    conn
    |> GSMLGAdminWeb.Guardian.Plug.sign_out()
    |> put_flash(:error, "#{type}: #{reason}")
    |> redirect(to: ~p"/sign_in")
  end
end
