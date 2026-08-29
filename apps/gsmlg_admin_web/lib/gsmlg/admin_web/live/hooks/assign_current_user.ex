defmodule GSMLG.AdminWeb.Live.Hooks.AssignCurrentUser do
  @moduledoc """
  LiveView on_mount hook that loads the current user from the Guardian session token.

  Guardian auth runs via Plug pipelines on the initial HTTP request, but LiveView
  mounts over WebSocket don't re-run plugs. This hook bridges the gap by decoding
  the Guardian JWT from the session and assigning `:current_user` to the socket.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [get_connect_info: 2, put_flash: 3, redirect: 2]

  alias GSMLG.Accounts
  alias GSMLG.Accounts.User
  alias GSMLG.AdminWeb.ClientCertificate
  alias GSMLG.AdminWeb.Plugs.ClientCertificateAuth

  def on_mount(:default, _params, session, socket) do
    current_user = load_user_from_session(session)
    auth_method = Map.get(session, ClientCertificateAuth.auth_method_key())

    case validate_certificate_session(socket, session, current_user, auth_method) do
      :ok ->
        socket =
          socket
          |> assign(:current_user, current_user)
          |> assign(:admin_auth_method, auth_method)

        {:cont, socket}

      :error ->
        socket =
          socket
          |> put_flash(:error, "Client certificate authentication expired.")
          |> redirect(to: "/sign_in")

        {:halt, socket}
    end
  end

  defp validate_certificate_session(_socket, _session, _current_user, auth_method)
       when auth_method != "client_certificate",
       do: :ok

  defp validate_certificate_session(socket, session, current_user, "client_certificate") do
    if ClientCertificateAuth.enabled?() do
      headers = get_connect_info(socket, :x_headers) || []
      expected_fingerprint = Map.get(session, ClientCertificateAuth.fingerprint_key())

      with %User{id: user_id} <- current_user,
           expected when is_binary(expected) <- expected_fingerprint,
           {:ok, %ClientCertificate{fingerprint: ^expected}} <-
             ClientCertificate.parse_headers(headers),
           %{user: %User{id: ^user_id}} <-
             Accounts.get_user_client_certificate_by_fingerprint(expected) do
        :ok
      else
        _ -> :error
      end
    else
      :ok
    end
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
