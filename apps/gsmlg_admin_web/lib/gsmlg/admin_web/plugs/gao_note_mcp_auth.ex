defmodule GSMLG.AdminWeb.Plugs.GaoNoteMCPAuth do
  @moduledoc """
  Authenticates GaoNote MCP admin requests with either a Guardian bearer token or
  the GaoNote MCP service API key.
  """

  import Plug.Conn

  alias GSMLG.AdminWeb.Guardian.ApiAuthErrorHandler
  alias GSMLG.GaoNote

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      api_key = api_key(conn) ->
        authenticate_api_key(conn, api_key)

      bearer_token = bearer_token(conn) ->
        authenticate_bearer(conn, bearer_token)

      true ->
        unauthorized(conn, {:unauthorized, :no_resource})
    end
  end

  defp authenticate_api_key(conn, api_key) do
    case GaoNote.verify_mcp_api_key(api_key) do
      {:ok, actor} ->
        assign(conn, :actor, actor)

      :error ->
        unauthorized(conn, {:invalid_token, :invalid_api_key})
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

  defp api_key(conn) do
    conn
    |> header_value("x-gaonote-mcp-key")
    |> case do
      nil -> header_value(conn, "x-api-key")
      value -> value
    end
    |> present()
  end

  defp bearer_token(conn) do
    conn
    |> header_value("authorization")
    |> case do
      "Bearer " <> token -> String.trim(token)
      "bearer " <> token -> String.trim(token)
      _other -> nil
    end
    |> present()
  end

  defp header_value(conn, name), do: conn |> get_req_header(name) |> List.first()

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
