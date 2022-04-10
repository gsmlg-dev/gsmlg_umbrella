defmodule GSMLG.Accounts.Auth do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.User

  def changeset(%User{} = user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
    |> put_password_hash()
  end

  def sign_in(attrs) do
    %User{}
    |> changeset(attrs)
    |> Repo.one()
  end

  def sign_up(attrs) do
    %User{}
    |> changeset(attrs)
    |> Repo.one()
  end

  defp put_password_hash(
         %Ecto.Changeset{valid?: true, changes: %{password: password}} = changeset
       ) do
    change(changeset, password: Argon2.hash_pwd_salt(password))
  end

  defp put_password_hash(changeset), do: changeset
end
