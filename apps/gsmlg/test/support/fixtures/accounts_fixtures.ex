defmodule GSMLG.AccountsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GSMLG.Accounts` context.
  """

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

  def client_certificate_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        certificate_der: :crypto.strong_rand_bytes(64),
        subject: "CN=Admin Client,O=GSMLG Test",
        email: "admin-client@example.test"
      },
      Map.new(overrides)
    )
  end

  def user_client_certificate_fixture(user, attrs \\ %{}) do
    {:ok, binding} =
      GSMLG.Accounts.bind_user_client_certificate(user, client_certificate_attrs(attrs))

    binding
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
