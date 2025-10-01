defmodule GSMLG.Accounts.MagicLinkEmail do
  @moduledoc """
  Phoenix 1.8 Magic Link Email implementation.
  """

  import Swoosh.Email

  @doc """
  Creates a magic link email for the user.
  """
  def magic_link_email(user, token) do
    base_url = Application.get_env(:gsmlg_web, :magic_link_base_url, "http://localhost:4110")
    magic_link_url = "#{base_url}/auth/magic-link/confirm?token=#{token}"

    new()
    |> to({user.name || user.username, user.email})
    |> from({"GSMLG", "noreply@gsmlg.net"})
    |> subject("Your magic login link")
    |> html_body(build_html_body(user, magic_link_url))
    |> text_body(build_text_body(user, magic_link_url))
  end

  defp build_html_body(user, magic_link_url) do
    """
    <html>
      <body>
        <h2>Hello #{user.name || user.username}! 👋</h2>

        <p>Click the button below to log in to your account:</p>

        <p>
          <a href="#{magic_link_url}" style="display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px; font-weight: bold;">
            Log In Now
          </a>
        </p>

        <p>Or copy and paste this link into your browser:</p>
        <p><code>#{magic_link_url}</code></p>

        <p><strong>This link will expire in 24 hours and can only be used once.</strong></p>

        <p>If you didn't request this login link, please ignore this email.</p>

        <p>— The GSMLG Team</p>
      </body>
    </html>
    """
  end

  defp build_text_body(user, magic_link_url) do
    """
    Hello #{user.name || user.username}!

    Click this link to log in to your account:
    #{magic_link_url}

    This link will expire in 24 hours and can only be used once.

    If you didn't request this login link, please ignore this email.

    — The GSMLG Team
    """
  end
end