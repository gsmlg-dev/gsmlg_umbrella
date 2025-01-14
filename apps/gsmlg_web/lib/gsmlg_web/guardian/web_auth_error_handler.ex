defmodule GSMLGWeb.Guardian.WebAuthErrorHandler do
  require Logger

  import Plug.Conn
  use GSMLGWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    Logger.error("Error occurred at #{__MODULE__}", error: reason, type: type)

    conn
    |> GSMLGWeb.Guardian.Plug.sign_out()
    |> put_flash(:error, "#{type}: #{reason}")
    |> redirect(to: ~p"/sign_in")
  end
end
