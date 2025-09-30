defmodule GSMLG.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GSMLG.Accounts` context.
  """

  alias GSMLG.Accounts
  alias GSMLG.Accounts.Scope

  @doc """
  Generate a user.
  """
  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{
        email: "email@test",
        name: "some name",
        username: "some_name",
        password: "some password"
      })
      |> GSMLG.Accounts.create_user()

    user
  end

  @doc """
  Generate a user_token.
  """
  def user_token_fixture(attrs \\ %{}) do
    {:ok, user_token} =
      attrs
      |> Enum.into(%{
        jti: "some token",
        aud: "some token_type"
      })
      |> GSMLG.Accounts.create_user_token()

    user_token
  end

  ## Phoenix 1.8 Scope Fixtures

  @doc """
  Generate a scope for testing.
  """
  def scope_fixture(attrs \\ %{}) do
    user = attrs[:user] || user_fixture()
    Scope.for_user(user)
  end
end
