defmodule GSMLG.Web.Plugs.AgentNoteParsers do
  @moduledoc false
  @behaviour Plug
  import Plug.Conn

  def init(opts), do: Plug.Parsers.init(opts)

  def call(conn, opts) do
    Plug.Parsers.call(conn, opts)
  rescue
    exception in [Plug.Parsers.ParseError, Plug.Parsers.UnsupportedMediaTypeError] ->
      if canonical?(conn.request_path) do
        malformed(conn)
      else
        reraise exception, __STACKTRACE__
      end
  end

  defp canonical?(path),
    do:
      path in ~w(/api/notes /api/labels /api/render) or
        String.starts_with?(path, ["/api/notes/", "/api/trash/"])

  defp malformed(conn) do
    structured =
      conn.method in ["PUT", "DELETE"] or
        conn.request_path in ~w(/api/notes/batch-labels /api/notes/batch-delete /api/trash/restore)

    if structured do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(
        400,
        Jason.encode!(%{
          code: "invalid_input",
          message: "Invalid JSON request body",
          details: %{},
          retryable: false
        })
      )
      |> halt()
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(400, "invalid JSON request body")
      |> halt()
    end
  end
end
