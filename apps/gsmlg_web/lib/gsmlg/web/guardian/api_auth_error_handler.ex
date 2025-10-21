defmodule GSMLG.Web.Guardian.ApiAuthErrorHandler do
  import Plug.Conn

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    # Get connection info safely
    remote_ip = case Plug.Conn.get_peer_data(conn) do
      %{remote_ip: ip} -> ip
      _ -> nil
    end

    GSMLG.Telemetry.error("API authentication error occurred",
      metadata: %{
        module: __MODULE__,
        error: reason,
        type: type,
        user_agent: get_req_header(conn, "user-agent"),
        remote_ip: remote_ip,
        request_path: conn.request_path
      }
    )

    body = Jason.encode!(%{message: "[ApiAuthErrorHandler] #{type}: #{reason}"})

    conn
    |> GSMLG.Web.Guardian.Plug.sign_out()
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
  end
end
