defmodule GSMLG.Repo.Migrations.SimplifyGaoNoteFields do
  use Ecto.Migration

  def up do
    alter table(:gao_notes) do
      add_if_not_exists :content, :text, null: false, default: ""
      add_if_not_exists :created_at, :utc_datetime_usec, null: false, default: fragment("now()")
    end

    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'body'
      ) THEN
        EXECUTE 'UPDATE gao_notes SET content = COALESCE(NULLIF(content, ''''), body, content) WHERE body IS NOT NULL';
      END IF;

      IF EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'gao_notes' AND column_name = 'inserted_at'
      ) THEN
        EXECUTE 'UPDATE gao_notes SET created_at = inserted_at WHERE inserted_at IS NOT NULL';
      END IF;
    END $$;
    """)

    drop_if_exists index(:gao_notes, [:created_by_id])

    alter table(:gao_notes) do
      remove_if_exists :body, :text
      remove_if_exists :body_format, :string
      remove_if_exists :created_by_id, references(:users, type: :string)
      remove_if_exists :updated_by_id, references(:users, type: :string)
      remove_if_exists :metadata, :map
      remove_if_exists :inserted_at, :utc_datetime_usec
    end
  end

  def down do
    :ok
  end
end
