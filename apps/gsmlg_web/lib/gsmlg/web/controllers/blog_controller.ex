defmodule GSMLG.Web.BlogController do
  use GSMLG.Web, :controller
  use Phoenix.Component

  alias GSMLG.Content

  action_fallback(GSMLG.Web.FallbackController)

  def index(conn, _params) do
    blogs = Content.list_blogs()
    locale = conn.assigns[:current_locale]

    translations =
      if locale do
        blogs
        |> Enum.map(fn blog ->
          case Content.get_translation(blog.id, locale) do
            %{status: "completed"} = t -> {blog.id, t}
            _ -> {blog.id, nil}
          end
        end)
        |> Map.new()
      else
        %{}
      end

    render(conn, :index, blogs: blogs, translations: translations)
  end

  def show(conn, %{"slug" => slug}) do
    blog = Content.get_blog_by_slug(slug)
    locale = conn.assigns[:current_locale]

    translation =
      if locale do
        Content.get_translation(blog.id, locale)
      end

    render(conn, :show, blog: blog, translation: translation)
  end
end
