defmodule GSMLG.AdminWeb.Plugs.BrowserBearerAuth do
  @moduledoc false

  import Plug.Conn

  alias GSMLG.AdminWeb.{BrowserAudit, BrowserAPI.Response}

  def init(opts), do: opts

  def call(conn, _opts) do
    case bearer_token(conn) do
      nil -> unauthorized(conn, "authentication_required")
      token -> authenticate(conn, token)
    end
  end

  defp authenticate(conn, token) do
    case GSMLG.AdminWeb.Guardian.resource_from_token(token, %{"typ" => "access"}, []) do
      {:ok, actor, _claims} ->
        conn
        |> GSMLG.AdminWeb.Guardian.Plug.put_current_resource(actor)
        |> assign(:actor, actor)

      {:error, _reason} ->
        unauthorized(conn, "authentication_required", "invalid_access_token")
    end
  end

  defp unauthorized(conn, public_code, audit_code \\ nil) do
    BrowserAudit.record(conn, "authenticate", "rejected", %{error_code: audit_code || public_code})

    conn
    |> Response.error(
      401,
      "authentication",
      public_code,
      "A valid Admin bearer access token is required.",
      false,
      "authenticate"
    )
    |> halt()
  end

  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> present(token)
      _other -> nil
    end
  end

  defp present(token) do
    case String.trim(token) do
      "" -> nil
      value -> value
    end
  end
end
