defmodule GSMLG.AdminWeb.GaoNoteMarkdownTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.GaoNoteMarkdown

  test "drops raw HTML and removes mixed-case, encoded, and malformed destinations" do
    note = %{
      id: "note-safe",
      attachments: [],
      content: """
      <img src=x onerror="alert(1)">
      <script>alert("raw")</script>
      <a href="https://example.com" onclick="alert(1)">raw link</a>
      <style>body { display: none }</style>

      [script](JaVaScRiPt:alert%281%29)
      [encoded](%6A%61%76%61%73%63%72%69%70%74%3Aalert%281%29)
      [double encoded](%256A%2561%2576%2561%2573%2563%2572%2569%2570%2574%253Aboom)
      [entity encoded](jav&#x61;script:boom)
      [entity colon](javascript&colon;boom)
      [vbscript](VbScRiPt:boom)
      [file](FiLe:///etc/passwd)
      [malformed](%ZZjavascript:boom)
      [data link](DaTa:text/html,boom)
      ![data image](dAtA:image/svg+xml,boom)
      [external](https://example.com/path)
      [anchor](#section)
      """
    }

    html = safe_html(note)
    document = Floki.parse_fragment!(html)

    refute html =~ "onerror="
    refute html =~ "onclick="
    refute html =~ "<script"
    refute html =~ "<style"
    refute html =~ "raw link"
    refute Regex.match?(~r/(?:javascript|vbscript|data|file):/i, html)
    assert Floki.attribute(document, "a", "href") == ["https://example.com/path", "#section"]
    assert Floki.attribute(document, "img", "src") == []
  end

  test "strictly allowlists final tags and attributes including IAL attributes" do
    note = %{
      id: "note-ial",
      attachments: [],
      content: """
      ## Safe heading
      {: #owned .danger onclick="alert(1)" style="color:red" data-extra="x"}

      [Safe link](https://example.com "Title")
      {: onclick="alert(2)" style="display:none" class="danger" data-extra="x"}

      | Name | Value |
      | --- | --- |
      | one | two |
      {: onclick="alert(3)" style="display:none"}

      ```elixir
      <script onclick="alert(4)">not executable</script>
      ```
      """
    }

    html = safe_html(note)
    document = Floki.parse_fragment!(html)
    allowed_tags = ~w(h2 p a table thead tbody tr th td pre code)
    attribute_names =
      document
      |> Floki.find("*")
      |> Enum.flat_map(fn {_tag, attributes, _children} ->
        Enum.map(attributes, fn {name, _value} -> name end)
      end)

    refute Enum.any?(
             attribute_names,
             &(Regex.match?(~r/\Aon/i, &1) or &1 in ["style", "id", "data-extra"])
           )

    refute html =~ "<script"
    assert html =~ "&lt;script"
    assert Floki.attribute(document, "a", "href") == ["https://example.com"]
    assert Floki.attribute(document, "a", "title") == ["Title"]
    assert [code_class] = Floki.attribute(document, "code", "class")
    assert code_class in ["elixir", "language-elixir"]

    assert document
           |> Floki.find("*")
           |> Enum.map(fn {tag, _attributes, _children} -> tag end)
           |> Enum.all?(&(&1 in allowed_tags))
  end

  test "rewrites only parsed known destinations and preserves titles, code, and unknown paths" do
    note_id = "note-routes"
    raw_url = "/gao_notes/notes/note-routes/attachments/docs/manual.txt"

    note = %{
      id: note_id,
      attachments: [%{path: "./docs/manual.txt"}],
      content: """
      [manual](./docs/manual.txt "Read this")
      ![manual image](./docs/%6Danual.txt)
      [unknown](./docs/unknown.txt)
      [traversal](../docs/manual.txt)
      `[code](./docs/manual.txt)`

      ```markdown
      ![fenced](./docs/manual.txt)
      ```
      """
    }

    document = note |> safe_html() |> Floki.parse_fragment!()

    assert Floki.attribute(document, ~s(a[title="Read this"]), "href") == [raw_url]
    assert Floki.attribute(document, "img", "src") == [raw_url]

    assert Floki.attribute(document, "a", "href") == [
             raw_url,
             "./docs/unknown.txt",
             "../docs/manual.txt"
           ]

    code = document |> Floki.find("code") |> Floki.text()
    assert code =~ "[code](./docs/manual.txt)"
    assert code =~ "![fenced](./docs/manual.txt)"
  end

  test "rewrites percent-encoded Unicode and special canonical paths" do
    path = "./资料/雪 file(1)\"100%.txt"

    note = %{
      id: "note-unicode",
      attachments: [%{path: path}],
      content: "[special](./%E8%B5%84%E6%96%99/%E9%9B%AA%20file%281%29%22100%25.txt)"
    }

    document = note |> safe_html() |> Floki.parse_fragment!()

    assert Floki.attribute(document, "a", "href") == [
             "/gao_notes/notes/note-unicode/attachments/%E8%B5%84%E6%96%99/" <>
               "%E9%9B%AA%20file%281%29%22100%25.txt"
           ]
  end

  test "generates syntax-safe image and file references" do
    assert GaoNoteMarkdown.reference(%{
             id: "simple",
             path: "./path",
             mime: "image/png",
             description: ""
           }) == "![simple](./path)"

    assert GaoNoteMarkdown.reference(%{
             id: "image-id",
             path: "./资料/a (b)\"100%.png",
             mime: "image/png",
             description: "line]\r\n(next)\""
           }) ==
             "![line\\] \\(next\\)\\\"]" <>
               "(./%E8%B5%84%E6%96%99/a%20%28b%29%22100%25.png)"

    assert GaoNoteMarkdown.reference(%{
             id: "ignored-description",
             path: "./docs/a] (b)\"100%雪.txt",
             mime: "text/plain",
             description: "Ignored"
           }) ==
             "[a\\] \\(b\\)\\\"100%雪.txt]" <>
               "(./docs/a%5D%20%28b%29%22100%25%E9%9B%AA.txt)"
  end

  defp safe_html(note) do
    note
    |> GaoNoteMarkdown.render()
    |> Phoenix.HTML.safe_to_string()
  end
end
