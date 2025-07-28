defmodule GSMLGWeb.UserSocket do
  use Phoenix.LiveView.Socket

  # A Socket handler
  #
  # It's possible to control the websocket connection and
  # assign values that can be accessed by your channel topics.

  ## Channels

  channel("node:lobby", GSMLGWeb.NodeChannel)
  channel("room:chess", GSMLGWeb.ChessChannel)

  # Socket params are passed from the client and can
  # be used to verify and authenticate a user. After
  # verification, you can put default assigns into
  # the socket that will be set for all channels, ie
  #
  #     {:ok, assign(socket, :user_id, verified_user_id)}
  #
  # To deny connection, return `:error`.
  #
  # See `Phoenix.Token` documentation for examples in
  # performing token verification on connect.
  @impl true
  def connect(%{"token" => token} = _params, socket, connect_info) do
    IO.inspect({:connected, :token, token, connect_info}, label: "UserSocket connect")

    case Guardian.Phoenix.Socket.authenticate(socket, GSMLGWeb.Guardian, token) do
      {:ok, authed_socket} ->
        {:ok, authed_socket}

      {:error, _} ->
        {:ok, socket}
    end
  end

  def connect(%{"_csrf_token" => csrf_token}, socket, connect_info) do
    token =
      case connect_info do
        %{session: %{"guardian_default_token" => token}} -> token
        _ -> nil
      end

    IO.inspect({:connected, :csrf_token, csrf_token, token, connect_info},
      label: "UserSocket connect"
    )

    claims_to_check = %{}
    key = Guardian.Plug.default_key()

    with {:ok, resource, claims} <-
           Guardian.resource_from_token(GSMLGWeb.Guardian, token, claims_to_check, []) do
      authed_socket = Guardian.Phoenix.Socket.assign_rtc(socket, resource, token, claims, key)

      {:ok, authed_socket}
    else
      _ -> {:ok, socket}
    end
  end

  # This function will be called when there was no authentication information
  @impl true
  def connect(_params, socket) do
    IO.inspect({:connected}, label: "UserSocket connect")
    {:ok, socket}
  end

  # Socket id's are topics that allow you to identify all sockets for a given user:
  #
  #     def id(socket), do: "user_socket:#{socket.assigns.user_id}"
  #
  # Would allow you to broadcast a "disconnect" event and terminate
  # all active sockets and channels for a given user:
  #
  #     Elixir.GSMLGWeb.Endpoint.broadcast("user_socket:#{user.id}", "disconnect", %{})
  #
  # Returning `nil` makes this socket anonymous.
  @impl true
  def id(socket) do
    case Guardian.Phoenix.Socket.current_resource(socket) do
      %{username: username} -> "user_socket:#{username}"
      _ -> "user_socket:$__nobody__"
    end
  end
end
