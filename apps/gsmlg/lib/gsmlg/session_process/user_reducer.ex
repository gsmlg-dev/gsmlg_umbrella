defmodule GSMLG.SessionProcess.UserReducer do
  use Phoenix.SessionProcess, :reducer
  alias Phoenix.SessionProcess.Action
  alias GSMLG.Accounts

  @name :user

  @impl true
  def init_state() do
    %{users: [], error: nil}
  end

  @impl true
  def handle_action(%Action{type: "list_users"}, state) do
    users = Accounts.list_users()

    %{state | users: users, error: nil}
  rescue
    error ->
      %{state | users: [], error: error}
  end

  def handle_action(%Action{type: "remove-user", payload: %{user_id: user_id}}, state) do
    user = Accounts.get_user!(user_id)
    {:ok, _} = Accounts.delete_user(user)

    new_users = state.users |> Enum.filter(&(&1.id != user_id))

    %{state | users: new_users, error: nil}
  end
end
