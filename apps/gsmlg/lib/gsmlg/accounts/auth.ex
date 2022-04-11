defmodule GSMLG.Accounts.Auth do
  use Ecto.Schema
  import Ecto.Changeset
  alias GSMLG.Accounts.Auth
  alias GSMLG.Accounts.User
  alias GSMLG.Repo
  import Ecto.Query, warn: false

  embedded_schema do
    field(:username, :string)
    field(:password, :string)
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

  def sign_up(attrs) do
    %Auth{}
    |> changeset(attrs)
    |> Repo.one()
  end

  defp find_user_pass(
         %Ecto.Changeset{changes: %{username: username, password: password}} = changeset
       ) do
    IO.puts("auth: \n")
    IO.puts(username)
    IO.puts(password)

    query =
      from(u in User,
        select: [
          :id,
          :username,
          :name,
          :email,
          :is_active,
          :portrait,
          :google_id,
          :apple_id,
          :github_id,
          :active_time
        ],
        where: [username: ^username, password: ^password]
      )

    case Repo.one(query) do
      nil -> {:error, changeset |> add_error(:password, "invalid password or username")}
      %User{} = user -> {:ok, user}
    end
  end
end
