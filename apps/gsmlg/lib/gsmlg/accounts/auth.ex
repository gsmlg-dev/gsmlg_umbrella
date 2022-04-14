defmodule GSMLG.Accounts.Auth do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts
  alias GSMLG.Accounts.Auth
  alias GSMLG.Accounts.User
  alias GSMLG.Repo
  import Ecto.Query, warn: false

  @primary_key false
  embedded_schema do
    field(:username, :string)
    field(:password, :string)
    field(:email, :string)
  end

  def changeset(%Auth{} = user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
  end

  def sign_in_changeset(%Auth{} = user, attrs) do
    user
    |> cast(attrs, [:username, :password])
    |> validate_required([:username, :password])
  end

  def sign_in(attrs) do
    %Auth{}
    |> sign_in_changeset(attrs)
    |> find_user_pass()
  end

  def sign_up_changeset(%Auth{} = user, attrs) do
    user
    |> cast(attrs, [:username, :password, :email])
    |> validate_required([:username, :password, :email])
    |> validate_format(:email, ~r/@/)
    |> validate_length(:password, min: 8, max: 32)
  end

  def sign_up(attrs) do
    %Auth{}
    |> sign_up_changeset(attrs)
    |> sign_up_user()
  end

  defp sign_up_user(changeset) do
    case changeset do
      %Ecto.Changeset{errors: errors} when length(errors) > 0 ->
        {:error, changeset}

      %Ecto.Changeset{changes: %{username: username, password: password, email: email}} ->
        Accounts.create_user(%{
          "username" => username,
          "password" => password,
          "email" => email
        })

      _ ->
        {:error, changeset |> add_error(:username, "¯\_(ツ)_/¯")}
    end
  end

  def gen_password() do
    random_string(14)
  end

  def gen_salt() do
    random_string(6)
  end

  defp find_user_pass(
         %Ecto.Changeset{changes: %{username: username, password: password}} = changeset
       ) do
    query =
      from(u in User,
        where: [username: ^username]
      )

    case Repo.one(query) do
      nil ->
        {:error, changeset |> add_error(:password, "invalid username or password")}

      %User{password_salt: password_salt} = user ->
        real_password = :crypto.mac(:hmac, :sha256, password_salt, password) |> Base.encode16()

        cond do
          real_password == user.password -> {:ok, user}
          true -> {:error, changeset |> add_error(:password, "invalid password or username")}
        end
    end
  end

  defp find_user_pass(%Ecto.Changeset{} = changeset) do
    {:error, changeset}
  end

  defp random_string(length) do
    :crypto.strong_rand_bytes(length) |> Base.url_encode64() |> binary_part(0, length)
  end
end
