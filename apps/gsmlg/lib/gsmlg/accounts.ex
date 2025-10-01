defmodule GSMLG.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias GSMLG.Repo

  alias GSMLG.Accounts.User
  alias GSMLG.Accounts.UserToken
  alias GSMLG.Accounts.Scope

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users do
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
        ]
      )

    Repo.all(query)
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(id) do
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
        ]
      )

    Repo.get!(query, id)
  end

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  ## Examples

      iex> delete_user(user)
      {:ok, %User{}}

      iex> delete_user(user)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{data: %User{}}

  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  alias GSMLG.Accounts.UserToken

  @doc """
  Returns the list of user_tokens.

  ## Examples

      iex> list_user_tokens()
      [%UserToken{}, ...]

  """
  def list_user_tokens do
    Repo.all(UserToken)
  end

  @doc """
  Gets a single user_token.

  Raises `Ecto.NoResultsError` if the User token does not exist.

  ## Examples

      iex> get_user_token!(123)
      %UserToken{}

      iex> get_user_token!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user_token!(jti) do
    query = from(ut in UserToken, where: [jti: ^jti])
    Repo.one!(query)
  end

  @doc """
  Creates a user_token.

  ## Examples

      iex> create_user_token(%{field: value})
      {:ok, %UserToken{}}

      iex> create_user_token(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_token(attrs \\ %{}) do
    %UserToken{}
    |> UserToken.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user_token.

  ## Examples

      iex> update_user_token(user_token, %{field: new_value})
      {:ok, %UserToken{}}

      iex> update_user_token(user_token, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_token(%UserToken{} = user_token, attrs) do
    user_token
    |> UserToken.update_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a user_token.

  ## Examples

      iex> delete_user_token(user_token)
      {:ok, %UserToken{}}

      iex> delete_user_token(user_token)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_token(%UserToken{} = user_token) do
    Repo.delete(user_token)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_token changes.

  ## Examples

      iex> change_user_token(user_token)
      %Ecto.Changeset{data: %UserToken{}}

  """
  def change_user_token(%UserToken{} = user_token, attrs \\ %{}) do
    UserToken.changeset(user_token, attrs)
  end

  ## Phoenix 1.8 Scoped Functions

  @doc """
  Returns the list of users scoped to the current user.

  ## Examples

      iex> list_users(scope)
      [%User{}, ...]

  """
  def list_users(%Scope{} = scope) do
    query =
      from(u in User,
        where: u.id == ^Scope.user_id(scope),
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
        ]
      )

    Repo.all(query)
  end

  def list_users(nil), do: []

  @doc """
  Gets a single user scoped to the current user.

  Raises `Ecto.NoResultsError` if the User does not exist or is not accessible.

  ## Examples

      iex> get_user!(scope, 123)
      %User{}

      iex> get_user!(scope, 456)
      ** (Ecto.NoResultsError)

  """
  def get_user!(%Scope{} = scope, id) do
    query =
      from(u in User,
        where: u.id == ^id and u.id == ^Scope.user_id(scope),
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
        ]
      )

    Repo.get!(query, id)
  end

  def get_user!(nil, _id), do: raise(Ecto.NoResultsError, "no user found")

  @doc """
  Gets a single user scoped to the current user.

  Returns `nil` if the User does not exist or is not accessible.

  ## Examples

      iex> get_user(scope, 123)
      %User{}

      iex> get_user(scope, 456)
      nil

  """
  def get_user(%Scope{} = scope, id) do
    query =
      from(u in User,
        where: u.id == ^id and u.id == ^Scope.user_id(scope),
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
        ]
      )

    Repo.get(query, id)
  end

  def get_user(nil, _id), do: nil

  ## Phoenix 1.8 Session Management

  @doc """
  Gets a user by session token.
  """
  def get_user_by_session_token(token) when is_binary(token) do
    query = from(ut in UserToken, where: ut.jti == ^token and ut.aud == "access")

    case Repo.one(query) do
      %UserToken{sub: user_id} -> Repo.get(User, user_id)
      nil -> nil
    end
  end

  def get_user_by_session_token(_token), do: nil
end
