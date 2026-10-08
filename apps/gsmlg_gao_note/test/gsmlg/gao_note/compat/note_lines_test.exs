defmodule GSMLG.GaoNote.Compat.NoteLinesTest do
  use ExUnit.Case, async: true
  alias GSMLG.GaoNote.Compat.NoteLines

  test "retains CR characters and final empty lines with one-based numbers" do
    assert %{
             id: "note",
             revision: 7,
             lines: [%{n: 1, text: "a\r"}, %{n: 2, text: "b"}, %{n: 3, text: ""}]
           } =
             NoteLines.from_note(%{id: "note", revision: 7, content: "a\r\nb\n"})

    assert %{lines: [%{n: 1, text: ""}], tag: "811c9dc5"} =
             NoteLines.from_note(%{id: "note", revision: 1, content: ""})
  end

  test "FNV-1a tags match independent published byte vectors" do
    for {content, tag} <- [{"a", "e40c292c"}, {"abc", "1a47e90b"}, {"foobar", "bf9cf968"}] do
      assert %{tag: ^tag} = NoteLines.from_note(%{id: "note", revision: 1, content: content})
    end
  end

  test "hashes raw UTF-8 bytes without normalizing line endings" do
    assert %{tag: "d1b30844"} = NoteLines.from_note(%{id: "note", revision: 2, content: "猫\r\n"})

    refute NoteLines.from_note(%{id: "note", revision: 2, content: "a\n"}).tag ==
             NoteLines.from_note(%{id: "note", revision: 2, content: "a\r\n"}).tag
  end
end
