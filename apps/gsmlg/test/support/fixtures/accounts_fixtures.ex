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
        active_time: ~U[2022-04-04 17:34:00Z],
        apple_id: "some apple_id",
        email: "some email",
        github_id: "some github_id",
        google_id: "some google_id",
        is_active: true,
        name: "some name",
        otp_token: "some otp_token",
        password: "some password",
        password_salt: "some password_salt",
        portrait: "some portrait",
        verify_code: 42
      })
      |> GSMLG.Accounts.create_user()

    user
  end
end
