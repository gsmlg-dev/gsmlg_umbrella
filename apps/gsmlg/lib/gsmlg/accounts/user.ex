defmodule GSMLG.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.UserToken

  schema "users" do
    field(:active_time, :utc_datetime)
    field(:apple_id, :string)
    field(:email, :string)
    field(:github_id, :string)
    field(:google_id, :string)
    field(:is_2fa_enabled, :boolean, default: false)
    field(:is_active, :boolean, default: false)
    field(:name, :string)
    field(:otp_token, :string)
    field(:password, :string)
    field(:password_salt, :string)
    field(:portrait, :string)
    field(:verify_code, :integer)
    field(:username, :string)

    has_many(:tokens, UserToken)

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :name,
      :email,
      :password,
      :verify_code,
      :portrait,
      :google_id,
      :apple_id,
      :github_id,
      :active_time
    ])
    |> validate_required([:username, :email, :password])
  end

  @doc false
  def create_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :name,
      :email,
      :password
    ])
    |> validate_required([:username, :email, :password])
    |> put_change(:password_salt, Ecto.UUID.generate())
  end
end
