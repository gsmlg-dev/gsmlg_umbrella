defmodule GSMLG.GaoNote.NoteChangesetTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.Note

  describe "create_changeset/2" do
    test "rejects an empty title" do
      assert_required_error(Note.create_changeset(%Note{}, valid_attrs(%{title: ""})), :title)
    end

    test "rejects a whitespace-only title" do
      assert_required_error(Note.create_changeset(%Note{}, valid_attrs(%{title: " \t\n"})), :title)
    end

    test "rejects empty content" do
      assert_required_error(Note.create_changeset(%Note{}, valid_attrs(%{content: ""})), :content)
    end

    test "rejects whitespace-only content" do
      assert_required_error(
        Note.create_changeset(%Note{}, valid_attrs(%{content: " \t\n"})),
        :content
      )
    end

    test "defaults an omitted description to an empty string" do
      changeset = Note.create_changeset(%Note{}, valid_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :description) == ""
    end
  end

  describe "changeset/2" do
    test "rejects updating the title to an empty string" do
      assert_required_error(Note.changeset(existing_note(), %{title: ""}), :title)
    end

    test "rejects updating the title to whitespace only" do
      assert_required_error(Note.changeset(existing_note(), %{title: " \t\n"}), :title)
    end

    test "rejects updating content to an empty string" do
      assert_required_error(Note.changeset(existing_note(), %{content: ""}), :content)
    end

    test "rejects updating content to whitespace only" do
      assert_required_error(Note.changeset(existing_note(), %{content: " \t\n"}), :content)
    end
  end

  defp assert_required_error(changeset, field) do
    refute changeset.valid?
    assert {"can't be blank", [validation: :required]} =
             Keyword.fetch!(changeset.errors, field)
  end

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(%{title: "Title", content: "Content"}, overrides)
  end

  defp existing_note do
    %Note{title: "Existing title", description: "", content: "Existing content"}
  end
end
