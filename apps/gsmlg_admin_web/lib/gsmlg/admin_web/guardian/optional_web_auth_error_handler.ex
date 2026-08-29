defmodule GSMLG.AdminWeb.Guardian.OptionalWebAuthErrorHandler do
  @behaviour Elixir.Guardian.Plug.ErrorHandler

  alias GSMLG.AdminWeb.Guardian
  alias GSMLG.AdminWeb.Guardian.WebAuthErrorHandler

  @impl true
  def auth_error(conn, {:unauthenticated, _reason} = error, opts) do
    WebAuthErrorHandler.auth_error(conn, error, opts)
  end

  def auth_error(conn, {_type, _reason}, _opts) do
    Guardian.Plug.sign_out(conn)
  end
end
