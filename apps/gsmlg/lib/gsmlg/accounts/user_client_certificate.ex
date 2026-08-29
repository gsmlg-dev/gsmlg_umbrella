defmodule GSMLG.Accounts.UserClientCertificate do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "user_client_certificates" do
    belongs_to(:user, User, type: :string)
    field(:fingerprint, :string)
    field(:certificate_der, :binary)
    field(:subject, :string)
    field(:email, :string)
    timestamps()
  end

  def create_changeset(binding, attrs) do
    binding
    |> cast(attrs, [:user_id, :fingerprint, :certificate_der, :subject, :email])
    |> validate_required([:user_id, :fingerprint, :certificate_der, :subject, :email])
    |> validate_format(:fingerprint, ~r/\A[0-9a-f]{64}\z/)
    |> foreign_key_constraint(:user_id, name: :user_client_certificates_user_id_fkey)
    |> unique_constraint(:fingerprint,
      name: :user_client_certificates_fingerprint_index
    )
    |> check_constraint(:fingerprint,
      name: :user_client_certificates_fingerprint_format
    )
  end
end
