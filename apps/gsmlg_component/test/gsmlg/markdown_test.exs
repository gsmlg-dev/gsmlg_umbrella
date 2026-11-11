defmodule GSMLG.Component.MarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.Component.Markdown

  test "renders blog Markdown, GFM tables and task lists on the server" do
    html =
      render_component(&Markdown.markdown/1,
        data: """
        # Blog heading

        **Bold** and [a link](https://example.com).

        | Name | Value |
        | --- | --- |
        | One | Two |

        - [x] Done

        ```elixir
        IO.puts("hello")
        ```
        """
      )

    assert html =~ "markdown-body"
    assert html =~ "Blog heading</h1>"
    assert html =~ "<strong>Bold</strong>"
    assert html =~ ~s(href="https://example.com")
    assert html =~ "<table>"
    assert html =~ ~s(type="checkbox")
    assert html =~ "disabled"
    assert html =~ "checked"
    assert html =~ "<pre"
    assert html =~ "hello"
  end

  test "does not render executable HTML or unsafe Markdown URLs" do
    html =
      render_component(&Markdown.markdown/1,
        data: """
        <script>alert('xss')</script>

        <img src=x onerror=alert(1)>

        [unsafe](javascript:alert%281%29)
        """
      )

    refute html =~ "<script"
    refute html =~ "onerror="
    refute html =~ "javascript:"
  end

  test "renders an empty preview when content is absent" do
    assert render_component(&Markdown.markdown/1, data: nil) =~ "markdown-body"
  end
end
