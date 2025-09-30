defmodule GSMLG.Accounts.Scope do
  @moduledoc """
  Phoenix 1.8 Scopes pattern implementation for security-by-default authorization.

  This module defines the scope struct that holds request-specific authorization
  data, enabling declarative data access control throughout the application.
  """

  alias GSMLG.Accounts.User

  defstruct user: nil

  @doc """
  Creates a new scope for the given user.
  """
  def for_user(%User{} = user) do
    %__MODULE__{user: user}
  end

  def for_user(nil), do: nil

  @doc """
  Checks if the scope has a valid user.
  """
  def has_user?(%__MODULE__{user: %User{}}), do: true
  def has_user?(_), do: false

  @doc """
  Gets the user ID from the scope.
  """
  def user_id(%__MODULE__{user: %User{id: user_id}}), do: user_id
  def user_id(_), do: nil
end