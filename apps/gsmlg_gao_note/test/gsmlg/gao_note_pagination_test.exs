defmodule GSMLG.GaoNotePaginationTest do
  use GSMLG.GaoNote.DataCase, async: true

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Note

  setup do
    Repo.delete_all(Note)
    :ok
  end

  test "count_notes excludes soft-deleted notes and ignores limit and offset" do
    note_fixture(%{title: "First"})
    note_fixture(%{title: "Second"})
    note_fixture(%{title: "Deleted", deleted_at: ~U[2026-10-17 00:00:00.000000Z]})

    assert GaoNote.count_notes() == 2
    assert GaoNote.count_notes(limit: 1, offset: 50) == 2
    assert GaoNote.count_notes(%{"limit" => "1", "offset" => "50"}) == 2
  end

  test "count_notes matches title and content searches including string-key options" do
    title_match = note_fixture(%{title: "Phoenix guide"})
    content_match = note_fixture(%{title: "Other", content: "A PHOENIX application"})
    note_fixture(%{title: "Unrelated"})
    note_fixture(%{title: "Phoenix deleted", deleted_at: ~U[2026-10-17 00:00:00.000000Z]})

    assert GaoNote.count_notes(search: " phoenix ") == 2
    assert GaoNote.count_notes(%{"search" => "PHOENIX", "limit" => 1}) == 2
    assert GaoNote.count_notes(search: "missing") == 0

    assert MapSet.new(Enum.map(GaoNote.list_notes(search: " phoenix "), & &1.id)) ==
             MapSet.new([title_match.id, content_match.id])
  end

  test "count_notes applies the same AND label filters and search as list_notes" do
    matching = labeled_note_fixture("Phoenix match", ["topic=ecto", "status=ready"])
    labeled_note_fixture("Phoenix other topic", ["topic=phoenix", "status=ready"])
    labeled_note_fixture("Phoenix missing status", ["topic=ecto"])
    labeled_note_fixture("Other title", ["topic=ecto", "status=ready"])

    opts = [search: "Phoenix", label: ["topic=ecto", "status=ready"]]
    matching_id = matching.id

    assert GaoNote.count_notes(opts) == 1
    assert [%Note{id: ^matching_id}] = GaoNote.list_notes(opts)
    assert GaoNote.count_notes(label: "topic=ecto") == 3
    assert GaoNote.count_notes(%{"label" => ["topic=ecto", "status=ready"]}) == 2
  end

  test "updated_at ties have stable disjoint pages without changing timestamp priority" do
    timestamp = ~U[2026-10-17 00:00:00.000000Z]

    ids =
      for number <- 1..5 do
        id = "00000000-0000-0000-0000-#{String.pad_leading(to_string(number), 12, "0")}"
        note_fixture(%{id: id, title: "Tied #{number}", updated_at: timestamp})
        id
      end

    newer =
      note_fixture(%{
        id: "00000000-0000-0000-0000-000000000000",
        title: "Newest",
        updated_at: ~U[2026-10-17 01:00:00.000000Z]
      })

    pages =
      for offset <- [0, 2, 4] do
        Enum.map(GaoNote.list_notes(limit: 2, offset: offset), & &1.id)
      end

    expected_ids = [newer.id | Enum.reverse(ids)]
    assert List.flatten(pages) == expected_ids

    assert Enum.map(GaoNote.list_notes(order_by: :updated_at), & &1.id) == expected_ids
  end

  defp note_fixture(attrs) do
    struct!(Note, Map.merge(%{title: "Note", content: "Body"}, attrs))
    |> Repo.insert!()
  end

  defp labeled_note_fixture(title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(%{title: title, content: "Body", labels: labels}, nil)

    note
  end
end
