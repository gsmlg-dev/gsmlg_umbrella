defmodule GSMLG.Repo.Migrations.AllowSshSyncPeers do
  use Ecto.Migration

  def change do
    execute(
      "ALTER TABLE gao_note_sync_peers ALTER COLUMN certificate_fingerprint DROP NOT NULL",
      "ALTER TABLE gao_note_sync_peers ALTER COLUMN certificate_fingerprint SET NOT NULL"
    )
  end
end
