defmodule GSMLG.AdminWeb.Live.Hooks.AssignCurrentUser do
  @moduledoc """
  LiveView on_mount hook that loads the current user from the Guardian session token.

  Guardian auth runs via Plug pipelines on the initial HTTP request, but LiveView
  mounts over WebSocket don't re-run plugs. This hook bridges the gap by decoding
  the Guardian JWT from the session and assigning `:current_user` to the socket.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, session, socket) do
    current_user = load_user_from_session(session)
    {:cont, assign(socket, :current_user, current_user)}
  end

  defp load_user_from_session(session) do
    with token when is_binary(token) <- Map.get(session, "guardian_default_token"),
         {:ok, resource, _claims} <-
           Guardian.resource_from_token(GSMLG.AdminWeb.Guardian, token, %{}, []) do
      resource
    else
      _ -> nil
    end
  end
end
