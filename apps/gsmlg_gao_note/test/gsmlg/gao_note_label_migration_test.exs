defmodule GSMLG.GaoNote.LabelMigrationTest do
  use GSMLG.GaoNote.DataCase, async: true

  alias GSMLG.GaoNote.Label

  test "persisted label timestamps match the Ecto schema" do
    assert [:inserted_at, :updated_at] -- Label.__schema__(:fields) == []

    assert Repo.query!("""
           SELECT column_name, data_type, is_nullable, datetime_precision
           FROM information_schema.columns
           WHERE table_schema = 'public'
             AND table_name = 'gao_note_labels'
             AND column_name IN ('inserted_at', 'updated_at')
           ORDER BY column_name
           """).rows == [
             ["inserted_at", "timestamp without time zone", "NO", 6],
             ["updated_at", "timestamp without time zone", "NO", 6]
           ]
  end
end
