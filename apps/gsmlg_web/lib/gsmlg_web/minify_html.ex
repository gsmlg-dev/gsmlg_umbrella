defmodule GSMLGWeb.MinifyHtml do
  @moduledoc """
  The `MinifyHtml` plug takes care of minifying
  the response body when the response content type is text/html.
  """

  @doc false
  def init(opts \\ []), do: opts

  @doc false
  def call(%Plug.Conn{} = conn, _ \\ []) do
    Plug.Conn.register_before_send(conn, &minify_html/1)
  end

  @doc false
  def minify_html(%Plug.Conn{} = conn) do
    case List.keyfind(conn.resp_headers, "content-type", 0) do
      {_, "text/html" <> _} ->
        case Floki.parse_document(conn.resp_body) do
          {:ok, document} ->
            resp_body = document |> Floki.raw_html()
            %Plug.Conn{conn | resp_body: resp_body}

          _ ->
            conn
        end

      _ ->
        conn
    end
  end
end
