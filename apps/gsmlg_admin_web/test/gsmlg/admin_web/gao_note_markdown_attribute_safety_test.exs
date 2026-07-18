defmodule GSMLG.AdminWeb.GaoNoteMarkdownAttributeSafetyTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.GaoNoteMarkdown

  test "final HTML cannot synthesize attributes from titles, alt text, raw HTML, or IALs" do
    html =
      render("""
      <img src=x onerror="alert(1)" style="display:block">

      [quoted](https://example.test 'safe" onclick="alert(1)')
      {: onclick="alert(1)" style="display:block" data-escape='" onload="alert(1)'}

      ![safe" onerror="alert(1)](./image.png 'image" onload="alert(1)')
      {: alt="IAL override" onclick="alert(1)" style="display:block"}
      """)

    document = Floki.parse_fragment!(html)
    attributes = all_attributes(document)

    refute Enum.any?(attributes, fn {name, _value} ->
             String.starts_with?(String.downcase(name), "on") or
               String.downcase(name) == "style"
           end)

    refute Enum.any?(attributes, fn {name, _value} ->
             name not in ["href", "src", "title", "alt"]
           end)

    assert [{"a", anchor_attributes, _children}] = Floki.find(document, "a")
    assert Enum.map(anchor_attributes, &elem(&1, 0)) |> Enum.sort() == ["href", "title"]
    assert attribute_value(anchor_attributes, "href") == "https://example.test"

    assert [{"img", image_attributes, _children}] = Floki.find(document, "img")
    assert Enum.map(image_attributes, &elem(&1, 0)) |> Enum.sort() == ["alt", "src", "title"]
    assert attribute_value(image_attributes, "alt") == ~s(safe" onerror="alert(1))
    refute attribute_value(image_attributes, "alt") == "IAL override"
    assert attribute_value(image_attributes, "src") == raw_url("./image.png")
  end

  test "numeric, named, percent, entity, and control scheme disguises lose destinations" do
    html =
      render("""
      [decimal](javascript&#58alert)
      [hex](vbscript&#x3a_boom)
      [data](data&#58text/html,boom)
      [named](javascript&colon;alert)
      [named control](java&Tab;script:alert)
      [percent entity](javascript%26%2358alert)
      [mixed control](java%26%23x0A%3Bscript%3Aalert)
      [mixed named](data%26colon%3Btext/html,boom)
      [mixed case](JaVaScRiPt%26%2358alert)
      ![unsafe image](data&#x3Aimage/svg+xml,boom)
      """)

    document = Floki.parse_fragment!(html)

    assert Floki.find(document, "a") != []
    assert Floki.find(document, "img") != []
    assert Enum.all?(Floki.find(document, "a"), &(attribute(&1, "href") == nil))
    assert Enum.all?(Floki.find(document, "img"), &(attribute(&1, "src") == nil))
  end

  test "exact and safely encoded known attachment paths still use authenticated raw routes" do
    attachments = [
      %{path: "./simple.txt"},
      %{path: "./space ü&name.txt"}
    ]

    html =
      render(
        """
        [simple](./simple.txt)
        [encoded](./space%20%C3%BC%26name.txt)
        [unknown](./unknown.txt)
        """,
        attachments
      )

    document = Floki.parse_fragment!(html)
    links = Map.new(Floki.find(document, "a"), &{Floki.text(&1), attribute(&1, "href")})

    assert links["simple"] == raw_url("./simple.txt")
    assert links["encoded"] == raw_url("./space ü&name.txt")
    assert links["unknown"] == "./unknown.txt"
  end

  defp render(content, attachments \\ [%{path: "./image.png"}]) do
    %{id: "note-id", content: content, attachments: attachments}
    |> GaoNoteMarkdown.render()
    |> Phoenix.HTML.safe_to_string()
  end

  defp raw_url(path), do: GaoNoteMarkdown.attachment_url("note-id", path)

  defp all_attributes(nodes) do
    Enum.flat_map(nodes, &node_attributes/1)
  end

  defp node_attributes({_tag, attributes, children}),
    do: attributes ++ all_attributes(children)

  defp node_attributes(_node), do: []

  defp attribute({_tag, attributes, _children}, name) do
    attribute_value(attributes, name)
  end

  defp attribute_value(attributes, name) do
    case List.keyfind(attributes, name, 0) do
      {^name, value} -> value
      nil -> nil
    end
  end
end
