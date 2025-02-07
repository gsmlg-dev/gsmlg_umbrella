defmodule GSMLG.Component.React do
  use Phoenix.Component
  import Phoenix.React.Helper

  @doc """
  Renders a markdown by react-dom/server.

  ## Examples

      <.react_markdown
        data={@markdown_doc}
      />

  """
  attr(:data, :string, required: true, doc: "markdown data")

  def react_markdown(assigns) do
    {static, props} = Map.pop(assigns, :static, true)

    react_component(%{
      component: "markdown",
      props: props,
      static: static
    })
  end

  def react_blog_form(assigns) do
    {static, props} = Map.pop(assigns, :static, nil)

    react_component(%{
      component: "blog_form",
      props: props,
      static: static
    })
  end
end
