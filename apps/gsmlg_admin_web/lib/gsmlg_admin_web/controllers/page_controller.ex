defmodule GSMLGAdminWeb.PageController do
  use GSMLGAdminWeb, :controller

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
end
