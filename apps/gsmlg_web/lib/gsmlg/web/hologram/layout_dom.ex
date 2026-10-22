defmodule GSMLG.Web.Hologram.LayoutDOM do
  @moduledoc false

  # Only trusted, server-rendered layout components enter this bridge. Their DOM
  # is serialized into Hologram state so SSR and client hydration share it.
  def from_rendered(rendered) do
    rendered
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> Floki.parse_fragment!()
    |> nodes()
  end

  defp nodes(tree), do: Enum.flat_map(tree, &convert_node/1)

  # The shared header's inline observer is mounted by the browser adapter.
  defp convert_node({"script", _attributes, _children}), do: []
  defp convert_node({:comment, _text}), do: []

  defp convert_node({tag, attributes, children}) do
    attributes =
      Enum.map(attributes, fn {name, value} ->
        # Floki lowercases the viewBox attribute used by shared SVG icons.
        name = if name == "viewbox", do: "viewBox", else: name
        {name, [text: value]}
      end)

    [{:element, tag, attributes, nodes(children)}]
  end

  defp convert_node(text) when is_binary(text), do: [{:text, text}]
end
