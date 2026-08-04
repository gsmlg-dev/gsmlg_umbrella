defmodule GSMLG.AdminWeb.Guardian.WebAuthErrorHandler do
  import Plug.Conn
  use GSMLG.AdminWeb, :controller

  @behaviour Guardian.Plug.ErrorHandler

  @impl Guardian.Plug.ErrorHandler
  def auth_error(conn, {type, reason}, _opts) do
    # Get connection info safely
    remote_ip =
      case Plug.Conn.get_peer_data(conn) do
        %{remote_ip: ip} -> ip
        _ -> nil
      end

    GSMLG.Telemetry.error("Admin authentication error occurred",
      metadata: %{
        module: __MODULE__,
        error: reason,
        type: type,
        user_agent: get_req_header(conn, "user-agent"),
        remote_ip: remote_ip
      }
    )

    conn
    |> GSMLG.AdminWeb.Guardian.Plug.sign_out()
    |> put_flash(:error, "#{type}: #{format_reason(reason)}")
    |> redirect(to: ~p"/sign_in")
  end

  defp format_reason(reason) do
    if is_exception(reason), do: Exception.message(reason), else: to_string(reason)
  end
end
