defmodule GSMLG.Repo.Migrations.AddKeyTypeToCertificateAuthorities do
  use Ecto.Migration

  def change do
    create table(:certificate_authorities, primary_key: false) do
      add :id, :string, primary_key: true, null: false
      add :subject, :string, null: false
      add :serial, :string, null: false
      add :status, :string, null: false, default: "active"

      # Certificate data
      add :certificate_pem, :text, null: false
      add :private_key_pem, :text, null: false
      add :public_key_pem, :text, null: false

      # New fields for enhanced PKI CA form
      add :key_type, :string, default: "rsa", null: false
      add :key_algorithm_details, :jsonb
      add :private_key_encrypted, :boolean, default: false, null: false

      # Validity period
      add :not_before, :utc_datetime_usec, null: false
      add :not_after, :utc_datetime_usec, null: false

      # Metadata
      add :ski, :string
      add :current_sequence, :bigint, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    # Indexes for efficient querying
    create unique_index(:certificate_authorities, [:serial], name: :certificate_authorities_serial_unique)
    create unique_index(:certificate_authorities, [:subject], name: :certificate_authorities_subject_unique)
    create index(:certificate_authorities, [:status])
    create index(:certificate_authorities, [:not_after])
  end
end
