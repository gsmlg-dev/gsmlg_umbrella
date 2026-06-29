defmodule GSMLG.Scout.MarkdownTest do
  use ExUnit.Case, async: true

  alias GSMLG.Scout.Markdown

  test "extracts the first level-one heading as title" do
    markdown =
      [
        "Intro",
        "## Ignored",
        "  #  Main Title  ",
        "# Later Title"
      ]
      |> Enum.join("\n")

    assert Markdown.title(markdown) == "Main Title"
    assert Markdown.title("## Subtitle") == nil
    assert Markdown.title(nil) == nil
  end

  test "counts words in markdown text" do
    assert Markdown.word_count("Hello, world! It's 2026-ready.") == 4
    assert Markdown.word_count(nil) == 0
  end
end
