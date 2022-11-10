defmodule GSMLGWeb.Guardian.WebAuthErrorHandler do
  import Plug.Conn
  use GSMLGWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    IO.puts("[WebAuthErrorHandler] #{type}: #{reason}")

    conn
    |> GSMLGWeb.Guardian.Plug.sign_out()
    |> put_flash(:error, "#{type}: #{reason}")
    |> redirect(to: ~p"/admin/sign_in")
  end
end
