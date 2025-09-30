defmodule GSMLG.Accounts.MagicLink do
  @moduledoc """
  Phoenix 1.8 Magic Link Authentication implementation.

  This module handles passwordless authentication using magic links sent via email.
  """

  import Ecto.Query, warn: false
  alias GSMLG.Repo
  alias GSMLG.Accounts.User
  alias GSMLG.Mailer
  alias GSMLG.Accounts.MagicLinkEmail

  @magic_link_validity_hours 24
  @magic_link_length 32

  @doc """
  Generates a magic link token for the given email address.
  """
  def generate_magic_link(email) when is_binary(email) do
    token = generate_secure_token()

    case Repo.get_by(User, email: email) do
      nil ->
        # Create new user if email doesn't exist
        create_user_with_magic_link(email, token)

      %User{} = user ->
        # Update existing user with new magic link
        update_user_magic_link(user, token)
    end
  end

  @doc """
  Validates a magic link token and returns the associated user if valid.
  """
  def validate_magic_link(token) when is_binary(token) do
    query = from u in User,
      where: u.magic_link_token == ^token and
             u.magic_link_sent_at > ^hours_ago(@magic_link_validity_hours)

    case Repo.one(query) do
      nil ->
        {:error, :invalid_or_expired_token}

      %User{} = user ->
        confirm_magic_link(user)
        {:ok, user}
    end
  end

  @doc """
  Sends magic link email to the user.
  """
  def send_magic_link_email(%User{} = user, token) do
    email = MagicLinkEmail.magic_link_email(user, token)
    Mailer.deliver(email)
  end

  @doc """
  Checks if user has confirmed their email via magic link.
  """
  def email_confirmed?(%User{email_confirmed_at: nil}), do: false
  def email_confirmed?(%User{email_confirmed_at: _confirmed_at}), do: true

  @doc """
  Revokes the current magic link token for a user.
  """
  def revoke_magic_link(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{
      magic_link_token: nil,
      magic_link_sent_at: nil
    })
    |> Repo.update()
  end

  ## Private Functions

  defp create_user_with_magic_link(email, token) do
    attrs = %{
      email: email,
      username: generate_username_from_email(email),
      magic_link_token: token,
      magic_link_sent_at: DateTime.utc_now(),
      is_active: true
    }

    %User{}
    |> User.create_changeset(attrs)
    |> Repo.insert()
  end

  defp update_user_magic_link(%User{} = user, token) do
    user
    |> Ecto.Changeset.change(%{
      magic_link_token: token,
      magic_link_sent_at: DateTime.utc_now()
    })
    |> Repo.update()
  end

  defp confirm_magic_link(%User{} = user) do
    now = DateTime.utc_now()

    user
    |> Ecto.Changeset.change(%{
      magic_link_confirmed_at: now,
      email_confirmed_at: now,
      magic_link_token: nil # Single-use token
    })
    |> Repo.update()
  end

  defp generate_secure_token do
    :crypto.strong_rand_bytes(@magic_link_length)
    |> Base.url_encode64()
    |> binary_part(0, @magic_link_length)
  end

  defp generate_username_from_email(email) do
    email
    |> String.split("@")
    |> List.first()
    |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
    |> then(fn base -> "#{base}_#{:rand.uniform(1000)}" end)
  end

  defp hours_ago(hours) do
    DateTime.utc_now()
    |> DateTime.add(-hours * 3600, :second)
  end
end