defmodule GSMLG.Repo.Migrations.CreateUserClientCertificates do
  use Ecto.Migration

  def change do
    create table(:user_client_certificates, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id,
          references(:users,
            type: :string,
            on_delete: :delete_all,
            name: :user_client_certificates_user_id_fkey
          ),
          null: false

      add :fingerprint, :string, size: 64, null: false
      add :certificate_der, :binary, null: false
      add :subject, :text, null: false
      add :email, :text, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:user_client_certificates, [:fingerprint],
             name: :user_client_certificates_fingerprint_index
           )

    create index(:user_client_certificates, [:user_id],
             name: :user_client_certificates_user_id_index
           )

    create constraint(
             :user_client_certificates,
             :user_client_certificates_fingerprint_format,
             check: "fingerprint ~ '^[0-9a-f]{64}$'"
           )
  end
end
