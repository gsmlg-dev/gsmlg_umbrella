defmodule GSMLG.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GSMLG.Accounts` context.
  """

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
end
