defmodule GSMLG.AccountFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `GSMLG.Account` context.
  """

  @doc """
  Generate a auth.
  """
  def auth_fixture(attrs \\ %{}) do
    {:ok, auth} =
      attrs
      |> Enum.into(%{})
      |> GSMLG.Account.create_auth()

    auth
  end
end
