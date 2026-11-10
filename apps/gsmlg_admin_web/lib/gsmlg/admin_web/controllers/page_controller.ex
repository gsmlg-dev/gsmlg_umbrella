defmodule GSMLG.AdminWeb.PageController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.Accounts.UserToken
  alias GSMLG.Accounts.User
  alias GSMLG.Content.Blog

  def index(conn, _params) do
    blog_count = Blog.count()
    user_count = User.count()
    token_count = UserToken.count()

    render(conn, :index,
      page_title: "Home",
      data: %{
        blog_count: blog_count,
        user_count: user_count,
        token_count: token_count
      }
    )
  end

  def caddy_disabled(conn, _params) do
    send_resp(conn, :not_found, "Not Found")
  end
end
