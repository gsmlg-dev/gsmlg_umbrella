defmodule GSMLG.Web.AgentNoteMCPPlug do
  @moduledoc "Authenticated canonical Agent Note endpoint using the Backplane transport."
  @behaviour Plug
  alias Backplane.McpProtocol.Server.Transport.StreamableHTTP
  alias GSMLG.Web.Plugs.AgentNoteMCPAuth

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put(:server, GSMLG.GaoNote.MCP.AgentNoteServer)
    # TODO(upstream): gsmlg-opt/backplane#56
    |> StreamableHTTP.Plug.init()
  end

  @impl Plug
  def call(conn, opts) do
    conn = AgentNoteMCPAuth.call(conn, [])
    if conn.halted, do: conn, else: StreamableHTTP.Plug.call(conn, opts)
  end
end
