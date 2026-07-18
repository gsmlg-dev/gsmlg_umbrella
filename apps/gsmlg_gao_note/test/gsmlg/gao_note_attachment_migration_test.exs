defmodule GSMLG.GaoNote.AttachmentMigrationTest do
  use GSMLG.GaoNote.DataCase, async: true

  alias GSMLG.GaoNote.Attachment

  @migration GSMLG.Repo.Migrations.RedesignGaoNoteAttachments
  @repo_root Path.expand("../../../..", __DIR__)
  @migration_file Path.join(
                    @repo_root,
                    "apps/gsmlg/priv/repo/migrations/20260718000000_redesign_gao_note_attachments.exs"
                  )

  unless Code.ensure_loaded?(@migration) do
    Code.compile_file(@migration_file)
  end

  test "persisted schema contains only the final attachment fields" do
    assert Attachment.__schema__(:fields) == [
             :id,
             :note_id,
             :storage_file_id,
             :path,
             :mime,
             :description,
             :inserted_at,
             :updated_at
           ]

    assert Attachment.__schema__(:associations) == [:note, :storage_file]

    assert Repo.query!(
             """
             SELECT
               column_name,
               data_type,
               is_nullable,
               column_default,
               datetime_precision
             FROM information_schema.columns
             WHERE table_schema = 'public'
               AND table_name = 'gao_note_attachments'
             ORDER BY ordinal_position
             """
           ).rows == [
             ["id", "text", "NO", nil, nil],
             ["note_id", "uuid", "NO", nil, nil],
             ["storage_file_id", "uuid", "NO", nil, nil],
             ["path", "text", "NO", nil, nil],
             ["mime", "text", "NO", nil, nil],
             ["description", "text", "NO", "''::text", nil],
             ["inserted_at", "timestamp without time zone", "NO", nil, 6],
             ["updated_at", "timestamp without time zone", "NO", nil, 6]
           ]
  end

  test "foreign keys use cascade for notes and restrict for storage files" do
    assert Repo.query!(
             """
             SELECT constraint_record.conname, constraint_record.confdeltype::text
             FROM pg_constraint AS constraint_record
             JOIN pg_class AS table_record
               ON table_record.oid = constraint_record.conrelid
             JOIN pg_namespace AS namespace_record
               ON namespace_record.oid = table_record.relnamespace
             WHERE namespace_record.nspname = 'public'
               AND table_record.relname = 'gao_note_attachments'
               AND constraint_record.contype = 'f'
             ORDER BY constraint_record.conname
             """
           ).rows == [
             ["gao_note_attachments_note_id_fkey", "c"],
             ["gao_note_attachments_storage_file_id_fkey", "r"]
           ]
  end

  test "indexes enforce global storage identity and per-note canonical paths" do
    assert Repo.query!(
             """
             SELECT
               index_record.relname,
               index_metadata.indisunique,
               array_agg(column_record.attname ORDER BY key_record.ordinality)
             FROM pg_class AS table_record
             JOIN pg_namespace AS namespace_record
               ON namespace_record.oid = table_record.relnamespace
             JOIN pg_index AS index_metadata
               ON index_metadata.indrelid = table_record.oid
             JOIN pg_class AS index_record
               ON index_record.oid = index_metadata.indexrelid
             JOIN LATERAL unnest(index_metadata.indkey)
               WITH ORDINALITY AS key_record(attnum, ordinality)
               ON true
             JOIN pg_attribute AS column_record
               ON column_record.attrelid = table_record.oid
              AND column_record.attnum = key_record.attnum
             WHERE namespace_record.nspname = 'public'
               AND table_record.relname = 'gao_note_attachments'
             GROUP BY index_record.relname, index_metadata.indisunique
             ORDER BY index_record.relname
             """
           ).rows == [
             ["gao_note_attachments_note_id_index", false, ["note_id"]],
             ["gao_note_attachments_note_id_path_index", true, ["note_id", "path"]],
             ["gao_note_attachments_pkey", true, ["id"]],
             ["gao_note_attachments_storage_file_id_index", true, ["storage_file_id"]]
           ]
  end

  test "changeset accepts text IDs, canonicalizes paths, and defaults description" do
    changeset =
      Attachment.changeset(%Attachment{}, %{
        id: "caller-global-id",
        note_id: Ecto.UUID.generate(),
        storage_file_id: Ecto.UUID.generate(),
        path: " docs\\./report..txt ",
        mime: "text/plain"
      })

    assert changeset.valid?

    assert %Attachment{
             id: "caller-global-id",
             path: "./docs/report..txt",
             mime: "text/plain",
             description: ""
           } = apply_changes(changeset)

    constraints =
      Enum.map(changeset.constraints, fn constraint ->
        {constraint.type, constraint.field, to_string(constraint.constraint)}
      end)

    assert {:foreign_key, :note_id, "gao_note_attachments_note_id_fkey"} in constraints

    assert {:foreign_key, :storage_file_id,
            "gao_note_attachments_storage_file_id_fkey"} in constraints

    assert constraints
           |> Enum.filter(fn {type, _field, _name} -> type == :unique end)
           |> Enum.map(fn {_type, _field, name} -> name end)
           |> Enum.sort() == [
             "gao_note_attachments_note_id_path_index",
             "gao_note_attachments_pkey",
             "gao_note_attachments_storage_file_id_index"
           ]
  end

  test "changeset requires every non-default persisted value" do
    attrs = %{
      id: "caller-global-id",
      note_id: Ecto.UUID.generate(),
      storage_file_id: Ecto.UUID.generate(),
      path: "./data.txt",
      mime: "text/plain"
    }

    for field <- [:id, :note_id, :storage_file_id, :path, :mime] do
      changeset = Attachment.changeset(%Attachment{}, Map.put(attrs, field, nil))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, field)
    end
  end

  test "changeset rejects invalid UTF-8 in every persisted text field" do
    attrs = %{
      id: "caller-global-id",
      note_id: Ecto.UUID.generate(),
      storage_file_id: Ecto.UUID.generate(),
      path: "./data.txt",
      mime: "text/plain",
      description: ""
    }

    for field <- [:id, :path, :mime, :description] do
      assert_invalid_text_error(
        Attachment.changeset(%Attachment{}, Map.put(attrs, field, <<255>>)),
        field,
        "must be valid UTF-8"
      )
    end
  end

  test "changeset rejects NUL bytes in every persisted text field" do
    attrs = %{
      id: "caller-global-id",
      note_id: Ecto.UUID.generate(),
      storage_file_id: Ecto.UUID.generate(),
      path: "./data.txt",
      mime: "text/plain",
      description: ""
    }

    for field <- [:id, :path, :mime, :description] do
      assert_invalid_text_error(
        Attachment.changeset(%Attachment{}, Map.put(attrs, field, <<"before", 0, "after">>)),
        field,
        "must not contain NUL bytes"
      )
    end
  end

  test "destructive migration is intentionally irreversible" do
    assert_raise RuntimeError,
                 "the GaoNote attachment hard break is intentionally irreversible",
                 fn -> @migration.down() end
  end

  defp assert_invalid_text_error(changeset, field, message) do
    refute changeset.valid?
    assert {^message, _metadata} = Keyword.fetch!(changeset.errors, field)
  end
end
