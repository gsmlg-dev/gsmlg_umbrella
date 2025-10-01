defmodule GSMLG.Web.Live.Hooks.FetchCurrentScope do
  @moduledoc """
  Phoenix 1.8 scope hook for LiveView that populates the scope in the socket's assigns.
  """

  use Phoenix.LiveView
  alias GSMLG.Accounts
  alias GSMLG.Accounts.Scope

  def on_mount(:default, _params, session, socket) do
    case session["user_token"] do
      nil ->
        {:cont, assign(socket, :current_scope, nil)}

      user_token ->
        case Accounts.get_user_by_session_token(user_token) do
          %Accounts.User{} = user ->
            scope = Scope.for_user(user)
            {:cont, assign(socket, :current_scope, scope)}

          nil ->
            {:cont, assign(socket, :current_scope, nil)}
        end
    end
  end
end