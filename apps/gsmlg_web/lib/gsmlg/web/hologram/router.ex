defmodule GSMLG.Web.Hologram.Router do
  @moduledoc false
  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    # Page GETs enter through the Phoenix browser pipeline; only Hologram's own
    # transport routes bypass the Phoenix router. POST /toolbox/svg2react stays
    # on its existing CSRF-protected Phoenix route.
    if String.starts_with?(conn.request_path, "/hologram/") do
      Hologram.Router.call(conn, Hologram.Router.init([]))
    else
      conn
    end
  end
end
