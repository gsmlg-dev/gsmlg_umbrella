defmodule GSMLG.Web.Plugs.VerifyMCPOrigin do
  @moduledoc """
  Validates browser Origin headers for public GaoNote MCP requests.
  """

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    origin = conn |> get_req_header("origin") |> List.first()

    if allowed_origin?(origin) do
      conn
    else
      conn
      |> send_resp(403, "Forbidden")
      |> halt()
    end
  end

  defp allowed_origin?(nil), do: true
  defp allowed_origin?(""), do: true

  defp allowed_origin?(origin) do
    origin in allowed_origins()
  end

  defp allowed_origins do
    configured = Application.get_env(:gsmlg_web, :mcp_allowed_origins, [])
    configured ++ ["http://localhost:4110", "http://127.0.0.1:4110"]
  end
end
