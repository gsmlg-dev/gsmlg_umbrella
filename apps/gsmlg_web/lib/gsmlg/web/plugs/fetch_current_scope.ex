defmodule GSMLG.Web.Plugs.FetchCurrentScope do
  @moduledoc """
  Phoenix 1.8 scope plug that fetches the current scope for authenticated users.

  This plug retrieves the user's session token, fetches the corresponding user
  from the database, builds the scope struct, and assigns it to the connection.
  """

  import Plug.Conn
  alias GSMLG.Accounts
  alias GSMLG.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :user_token) do
      nil ->
        assign(conn, :current_scope, nil)

      user_token ->
        case Accounts.get_user_by_session_token(user_token) do
          %Accounts.User{} = user ->
            scope = Scope.for_user(user)
            assign(conn, :current_scope, scope)

          nil ->
            assign(conn, :current_scope, nil)
        end
    end
  end
end
