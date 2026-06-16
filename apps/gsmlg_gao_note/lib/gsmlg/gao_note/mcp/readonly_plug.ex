defmodule GSMLG.GaoNote.MCP.ReadOnlyPlug do
  @moduledoc false

  @behaviour Plug

  alias Anubis.Server.Transport.StreamableHTTP

  @impl Plug
  def init(opts) do
    opts
    |> Keyword.put(:server, GSMLG.GaoNote.MCP.ReadOnlyServer)
    |> StreamableHTTP.Plug.init()
  end

  @impl Plug
  def call(conn, opts), do: StreamableHTTP.Plug.call(conn, opts)
end
