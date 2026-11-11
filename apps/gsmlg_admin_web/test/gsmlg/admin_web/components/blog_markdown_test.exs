defmodule GSMLG.AdminWeb.BlogMarkdownTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  test "blog preview renders Markdown without a JavaScript renderer" do
    html =
      render_component(&GSMLG.AdminWeb.BlogLive.Index.render/1,
        flash: %{},
        live_action: :show,
        page_title: "Blog preview",
        active_menu: "blog_list",
        blog: %GSMLG.Content.Blog{
          id: "preview",
          slug: "preview",
          title: "Preview",
          author: "Author",
          date: ~D[2026-11-11],
          content: "# Preview heading\n\n**Preview body**"
        }
      )

    assert html =~ "Preview heading</h1>"
    assert html =~ "<strong>Preview body</strong>"
  end
end
