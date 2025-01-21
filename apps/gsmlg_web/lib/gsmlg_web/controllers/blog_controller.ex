defmodule GSMLGWeb.BlogController do
  use GSMLGWeb, :tool_controller
  use Phoenix.Component

  alias GSMLG.Content
  # alias GSMLG.Content.Blog

  action_fallback(GSMLGWeb.FallbackController)

  def index(conn, _params) do
    assigns = %{}

    header_slot = ~H"""
    <div class="header-hero-container">
      <h1 class="header-hero-text">
        Blog
      </h1>
    </div>
    """

    blogs = Content.list_blogs()
    render(conn, :index, blogs: blogs, header_slot: header_slot)
  end

  def show(conn, %{"slug" => slug}) do
    blog = Content.get_blog_by_slug(slug)

    assigns = %{blog: blog}

    header_slot = ~H"""
    <div class="header-hero-container flex-col">
      <h1 class={[
        "header-hero-text",
        "w-full px-4",
        "flex justify-center items-center",
        "text-6xl whitespace-auto"
      ]}>
        {@blog.title}
      </h1>
      <author class="text-2xl text-fuchsia-300 my-4">
        {@blog.author}
      </author>
      <time class="text-xl text-pink-300">{@blog.date}</time>
    </div>
    """

    render(conn, :show, blog: blog, header_slot: header_slot)
  end
end
