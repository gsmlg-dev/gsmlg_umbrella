defmodule GSMLGWeb.AuthView do
  use GSMLGWeb, :view

  def render("sign_in.json", %{username: username, token: token}) do
    %{
      username: username,
      token: token
    }
  end

  def render("sign_up.json", %{username: username}) do
    %{success: true, username: username}
  end

  # def render("error.json", %{changeset: changeset}) do
  #   %{errors: []}
  # end
end
