defmodule GSMLG.AdminWeb.Plugs.AdminBearerAuth do
  @moduledoc """
  Authenticates admin JSON API requests with a Guardian Bearer access token.
  """

  import Plug.Conn

  alias GSMLG.AdminWeb.Guardian.ApiAuthErrorHandler

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil -> unauthorized(conn, {:unauthorized, :no_resource})
      token -> authenticate_bearer(conn, token)
    end
  end

  defp authenticate_bearer(conn, token) do
    case GSMLG.AdminWeb.Guardian.resource_from_token(token, %{"typ" => "access"}, []) do
      {:ok, user, _claims} ->
        conn
        |> GSMLG.AdminWeb.Guardian.Plug.put_current_resource(user)
        |> assign(:actor, user)

      {:error, reason} ->
        unauthorized(conn, {:invalid_token, reason})
    end
  end

  defp bearer_token(conn) do
    conn
    |> get_req_header("authorization")
    |> List.first()
    |> case do
      "Bearer " <> token -> String.trim(token)
      _other -> nil
    end
    |> present()
  end

  defp present(nil), do: nil

  defp present(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp unauthorized(conn, reason) do
    conn
    |> ApiAuthErrorHandler.auth_error(reason, [])
    |> halt()
  end
end
