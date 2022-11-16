defmodule GSMLGWeb.BlogController do
  use GSMLGWeb, :controller

  alias GSMLG.Content
  # alias GSMLG.Content.Blog

  action_fallback GSMLGWeb.FallbackController

  def index(conn, _params) do
    blogs = Content.list_blogs()
    render(conn, :index, blogs: blogs)
  end

  def show(conn, %{"slug" => slug}) do
    blog = Content.get_blog_by_slug(slug)
    render(conn, :show, blog: blog)
  end
end
