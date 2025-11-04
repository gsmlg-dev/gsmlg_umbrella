defmodule GSMLG.Repo.Migrations.CreatePKICSRRequests do
  use Ecto.Migration

  def change do
    create table(:pki_csr_requests) do
      add :csr_pem, :text, null: false
      add :subject, :string, null: false
      add :requested_by, :string, null: false
      add :status, :string, default: "pending", null: false
      add :ca_id, :string, null: false
      add :template, :string, default: "server"
      add :validity_days, :integer, default: 365
      add :notes, :text
      add :certificate_serial, :bigint

      timestamps()
    end

    create index(:pki_csr_requests, [:status])
    create index(:pki_csr_requests, [:ca_id])
    create index(:pki_csr_requests, [:requested_by])
    create index(:pki_csr_requests, [:certificate_serial])
  end
end
