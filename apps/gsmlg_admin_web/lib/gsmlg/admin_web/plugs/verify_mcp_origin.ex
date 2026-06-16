defmodule GSMLG.AdminWeb.Plugs.VerifyMCPOrigin do
  @moduledoc """
  Validates browser Origin headers for authenticated GaoNote MCP requests.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = conn |> get_req_header("origin") |> List.first()

    if allowed_origin?(origin) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{message: "Forbidden Origin"}))
      |> halt()
    end
  end

  defp allowed_origin?(nil), do: true
  defp allowed_origin?(""), do: true

  defp allowed_origin?(origin) do
    origin in allowed_origins()
  end

  defp allowed_origins do
    configured = Application.get_env(:gsmlg_admin_web, :mcp_allowed_origins, [])
    configured ++ ["http://localhost:4111", "http://127.0.0.1:4111"]
  end
end
