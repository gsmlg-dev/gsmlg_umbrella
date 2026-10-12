defmodule GSMLG.Repo.Migrations.AddGaoNoteSync do
  use Ecto.Migration

  def change do
    create table(:gao_note_sync_peers, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :certificate_fingerprint, :text, null: false
      add :actor_id, :text, null: false
      add :allowed_selectors, {:array, :text}, null: false
      add :selectors, {:array, :text}, null: false, default: []
      add :session_id, :uuid
      add :max_blob_bytes, :bigint, null: false, default: 536_870_912
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gao_note_sync_peers, [:certificate_fingerprint])

    # Heads, memberships, receipts and permanent tombstones deliberately survive note deletion.
    create table(:gao_note_sync_records, primary_key: false) do
      add :id, :text, primary_key: true
      add :kind, :text, null: false
      add :peer_id, references(:gao_note_sync_peers, type: :uuid, on_delete: :restrict)
      add :note_id, :uuid
      add :data, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:gao_note_sync_records, [:peer_id, :kind, :note_id])

    create table(:gao_note_sync_pins, primary_key: false) do
      add :owner_id, references(:gao_note_sync_records, type: :text, on_delete: :delete_all),
        primary_key: true

      add :storage_file_id, references(:storage_files, type: :uuid, on_delete: :restrict),
        primary_key: true
    end

    create index(:gao_note_sync_pins, [:storage_file_id])
  end
end
