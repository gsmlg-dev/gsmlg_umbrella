defmodule GSMLGAdminWeb.BlogJSON do
  alias GSMLG.Content.Blog

  # If you want to customize a particular status code,
  # you may add your own clauses, such as:
  #
  @doc """
  Renders a list of blogs.
  """
  def index(%{blogs: blogs}) do
    %{data: for(blog <- blogs, do: data(blog))}
  end

  @doc """
  Renders a single blog.
  """
  def show(%{blog: blog}) do
    %{data: data(blog)}
  end

  defp data(%Blog{} = blog) do
    %{
      id: blog.id,
      title: blog.title,
      date: blog.date,
      author: blog.author,
      content: blog.content,
      slug: blog.slug
    }
  end

  # By default, Phoenix returns the status message from
  # the template name. For example, "404.json" becomes
  # "Not Found".
  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end
end
