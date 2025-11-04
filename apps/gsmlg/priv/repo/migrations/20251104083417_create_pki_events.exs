defmodule GSMLG.Repo.Migrations.CreatePkiEvents do
  use Ecto.Migration

  def change do
    # Main events table for PKI event sourcing
    create table(:pki_events, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :event_type, :string, null: false
      add :timestamp, :utc_datetime_usec, null: false
      add :sequence, :bigint, null: false
      add :ca_id, :string, null: false
      add :metadata, :jsonb, null: false, default: "{}"
      add :actor, :string
      add :correlation_id, :string

      # PostgreSQL-specific: automatically track when record inserted
      add :inserted_at, :utc_datetime_usec, null: false, default: fragment("NOW()")
    end

    # Indexes for query patterns
    # Primary index for querying events by CA with sequence ordering
    create index(:pki_events, [:ca_id, :sequence], name: :pki_events_ca_id_sequence_idx)

    # Index for querying events by type with timestamp ordering
    create index(:pki_events, [:event_type, :timestamp],
             name: :pki_events_event_type_timestamp_idx
           )

    # General timestamp index for time-range queries
    create index(:pki_events, [:timestamp])

    # Index for correlation tracking across events
    create index(:pki_events, [:correlation_id])

    # GIN index for efficient JSONB queries on metadata
    execute(
      "CREATE INDEX pki_events_metadata_gin_idx ON pki_events USING GIN (metadata)",
      "DROP INDEX pki_events_metadata_gin_idx"
    )

    # Specific index for certificate serial queries (most common pattern)
    execute(
      "CREATE INDEX pki_events_metadata_serial_idx ON pki_events ((metadata->>'serial'))",
      "DROP INDEX pki_events_metadata_serial_idx"
    )

    # Unique constraint on sequence per CA to prevent duplicates
    create unique_index(:pki_events, [:ca_id, :sequence], name: :pki_events_ca_sequence_unique)
  end
end
