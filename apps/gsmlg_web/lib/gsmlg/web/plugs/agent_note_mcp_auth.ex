defmodule GSMLG.Web.Plugs.AgentNoteMCPAuth do
  @moduledoc "Authenticates the public MCP endpoint using public Guardian or GaoNote service keys."
  @behaviour Plug
  import Plug.Conn
  alias GSMLG.GaoNote

  @impl Plug
  def init(opts), do: opts
  @impl Plug
  def call(conn, _opts) do
    with {:ok, credential} <- credential(conn),
         {:ok, actor} <- authenticate(credential) do
      conn |> assign(:actor, actor) |> assign(:current_user, actor)
    else
      _error -> unauthorized(conn)
    end
  end

  defp credential(conn) do
    keys = get_req_header(conn, "x-gaonote-mcp-key") ++ get_req_header(conn, "x-api-key")
    bearer = get_req_header(conn, "authorization")

    case {keys, bearer} do
      {[key], []} when key != "" ->
        {:ok, {:key, key}}

      {[], [authorization]} ->
        case String.split(authorization, " ", parts: 2) do
          [scheme, token] when token != "" ->
            if String.downcase(scheme) == "bearer" and String.trim(token) != "",
              do: {:ok, {:bearer, String.trim(token)}},
              else: :error

          _other ->
            :error
        end

      _other ->
        :error
    end
  end

  defp authenticate({:key, key}), do: GaoNote.verify_mcp_api_key(key)

  defp authenticate({:bearer, token}) do
    case GSMLG.Web.Guardian.resource_from_token(token, %{"typ" => "access"}, []) do
      {:ok, user, _claims} -> {:ok, user}
      {:error, _reason} -> :error
    end
  rescue
    Ecto.NoResultsError -> :error
  end

  defp unauthorized(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> put_resp_content_type("application/json")
    |> send_resp(401, JSON.encode!(%{error: "unauthorized"}))
    |> halt()
  end
end
