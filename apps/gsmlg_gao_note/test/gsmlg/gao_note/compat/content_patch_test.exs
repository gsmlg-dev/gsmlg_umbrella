defmodule GSMLG.GaoNote.Compat.ContentPatchTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.Compat.ContentPatch

  test "applies strict context hunks and preserves original line endings" do
    for {content, patch, expected} <- [
          {"before\nold\nafter\n", "@@\n before\n-old\n+new\n after", "before\nnew\nafter\n"},
          {"zero\none\ntwo\nthree\nfour\n", "@@\n one\n-two\n+TWO\n@@\n three\n-four\n+FOUR",
           "zero\none\nTWO\nthree\nFOUR\n"},
          {"α\r\nold\nβ\r\nlast", "@@\n α\n-old\n+新\n β", "α\r\n新\r\nβ\r\nlast"},
          {"a\nb\r\nc\n", "@@\n a\n b\n-c\n+C", "a\nb\r\nC\n"},
          {"tail", "@@\n tail\n+next", "tail\nnext"},
          {"head\r\ntail", "@@\n head\n tail\n+next", "head\r\ntail\r\nnext"},
          {"kept\nremoved", "@@\n kept\n-removed", "kept"},
          {"kept\r\nremoved", "@@\n kept\n-removed", "kept"},
          {"a\nb\r\nlast", "@@\n a\n b", "a\nb\r\nlast"},
          {"old\r\n", "@@\r\n-old\r\n+new\r\n", "new\r\n"},
          {"old\n", "@@\n-old\n+new\r", "new\n"},
          {"old", "@@\n-old\n+new", "new"},
          {"old", "@@\n-old", ""},
          {"\n", "@@\n-\n+new", "new\n"}
        ] do
      assert {:ok, ^expected} = ContentPatch.apply(content, patch)
    end
  end

  test "rejects invalid, fuzzy, ambiguous, unanchored and unordered patches" do
    for {patch, content} <- [
          {"@@", "old\n"},
          {"@@\n+new", "old\n"},
          {"@@\n-missing\n+new", "old\n"},
          {"@@\n same\n-old\n+new", "same\nold\nsame\nold\n"},
          {"@@\n-old \n+new", "old\n"},
          {"@@\n a\n-b\n+B\n@@\n b\n-c\n+C", "a\nb\nc\n"},
          {"@@\n three\n-four\n+FOUR\n@@\n one\n-two\n+TWO", "one\ntwo\nthree\nfour\n"},
          {"*** Update File: note.md\n@@\n-old\n+new", "old\n"},
          {"*** Begin Patch\n@@\n-old\n+new\n*** End Patch", "old\n"},
          {"@@ -1 +1 @@\n-old\n+new", "old\n"},
          {"@@\n-old\n+new\n\\ No newline at end of file", "old\n"},
          {"@@\n-old\n+new\n@@\n-missing\n+other", "old\n"},
          {"@@\n-old\n+new\n@@", "old\n"},
          {"@@\n\n-old\n+new", "old\n"},
          {"@@\n ", ""}
        ] do
      assert {:error, reason} = ContentPatch.apply(content, patch)
      assert is_binary(reason)
    end
  end

  test "duplicate uniquely anchored patterns reach overlap validation" do
    assert {:error, "hunks must be ordered and must not overlap"} =
             ContentPatch.apply("old\n", "@@\n-old\n+first\n@@\n-old\n+second")
  end

  test "empty hunks preserve reference parser line numbers" do
    assert {:error, "invalid hunk at line 4, Update hunk does not contain any lines"} =
             ContentPatch.apply("old\n", "@@")

    assert {:error, "invalid hunk at line 7, Update hunk does not contain any lines"} =
             ContentPatch.apply("old\n", "@@\n-old\n+new\n@@")

    assert {:error,
            "invalid hunk at line 4, Unexpected line found in update hunk: '@@'. Every line should start with ' ' (context line), '+' (added line), or '-' (removed line)"} =
             ContentPatch.apply("old\n", "@@\n@@\n-old\n+new")
  end

  test "matches many uniquely anchored hunks with long repeated prefixes" do
    {content, patch, expected} =
      Enum.reduce(0..191, {"", "", ""}, fn n, {content, patch, expected} ->
        prefix = String.duplicate("repeated prefix\n", 48)
        context = String.duplicate(" repeated prefix\n", 48)

        {content <> prefix <> "anchor-#{n}\n",
         patch <> "@@\n" <> context <> "-anchor-#{n}\n+updated-#{n}\n",
         expected <> prefix <> "updated-#{n}\n"}
      end)

    assert {:ok, ^expected} = ContentPatch.apply(content, patch)
  end

  test "detects ambiguous original context before applying any hunk" do
    content =
      Enum.map_join(0..63, fn n -> "repeated prefix\nanchor-#{if n == 63, do: 0, else: n}\n" end)

    patch =
      Enum.map_join(0..63, fn n -> "@@\n repeated prefix\n-anchor-#{n}\n+updated-#{n}\n" end)

    assert {:error, "context must match exactly one location in the original content"} =
             ContentPatch.apply(content, patch)
  end
end
