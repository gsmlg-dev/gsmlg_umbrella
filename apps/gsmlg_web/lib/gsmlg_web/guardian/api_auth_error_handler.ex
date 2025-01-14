defmodule GSMLGWeb.Guardian.ApiAuthErrorHandler do
  import Plug.Conn

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    Logger.error("Error occurred at #{__MODULE__}", error: reason, type: type)
    body = Jason.encode!(%{message: "[ApiAuthErrorHandler] #{type}: #{reason}"})

    conn
    |> GSMLGWeb.Guardian.Plug.sign_out()
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
  end
end
