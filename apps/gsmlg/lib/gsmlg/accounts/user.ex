defmodule GSMLG.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.UserToken
  alias GSMLG.Accounts.Auth

  @primary_key {:id, :string, autogenerate: false}
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

    has_many(:tokens, UserToken, foreign_key: :sub)

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
      :email,
      :password
    ])
    |> validate_required([:username, :email, :password])
    |> put_change(:id, Ecto.UUID.generate())
    |> put_change(:password_salt, Auth.gen_salt())
    |> update_password()
    |> unique_constraint(:email)
    |> unique_constraint(:username)
  end

  def update_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :name,
      :email,
      :password,
      :portrait,
      :otp_token,
      :is_2fa_enabled
    ])
    |> match_if_password()
  end

  defp update_password(
         %Ecto.Changeset{changes: %{password_salt: salt, password: password}} = changeset
       ) do
    real_password = :crypto.mac(:hmac, :sha256, salt, password) |> Base.encode16()
    put_change(changeset, :password, real_password)
  end

  defp match_if_password(changeset) do
    case changeset do
      %Ecto.Changeset{changes: %{password: password}} ->
        update_password(changeset)

      _ ->
        changeset
    end
  end
end
