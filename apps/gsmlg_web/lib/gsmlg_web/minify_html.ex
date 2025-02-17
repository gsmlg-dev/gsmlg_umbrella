defmodule GSMLGWeb.MinifyHtml do
  @moduledoc """
  The `MinifyHtml` plug takes care of minifying
  the response body when the response content type is text/html.
  """
  require Logger

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
        binary_body = IO.iodata_to_binary(conn.resp_body)

        resp_body =
          HtmlMinifier.minify(binary_body, %HtmlMinifier{
            keep_closing_tags: true,
            keep_html_and_head_opening_tags: true,
            keep_spaces_between_attributes: true,
            minify_css: true,
            minify_js: true,
            remove_bangs: true,
            remove_processing_instructions: true,
            do_not_minify_doctype: true,
            ensure_spec_compliant_unquoted_attribute_values: true,
            keep_comments: false,
            keep_input_type_text_attr: false,
            keep_ssi_comments: false,
            preserve_brace_template_syntax: true,
            preserve_chevron_percent_template_syntax: true
          })

        Logger.debug(inspect({"Convert!", binary_body, resp_body}))
        %Plug.Conn{conn | resp_body: resp_body}

      _ ->
        conn
    end
  end
end
