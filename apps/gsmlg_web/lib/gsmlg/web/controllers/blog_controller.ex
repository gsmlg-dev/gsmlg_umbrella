defmodule GSMLG.Web.BlogController do
  use GSMLG.Web, :controller
  use Phoenix.Component

  alias GSMLG.Content
  # alias GSMLG.Content.Blog

  action_fallback(GSMLG.Web.FallbackController)

  def index(conn, _params) do
    blogs = Content.list_blogs()
    render(conn, :index, blogs: blogs)
  end

  def show(conn, %{"slug" => slug}) do
    blog = Content.get_blog_by_slug(slug)

    render(conn, :show, blog: blog)
  end
end
