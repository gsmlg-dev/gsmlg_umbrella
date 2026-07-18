defmodule GSMLG.GaoNote.MCP.AuthorizationTest do
  use ExUnit.Case, async: true

  alias GSMLG.GaoNote.MCP.Authorization

  @unauthorized {:error, "Admin MCP mutating tools require an actor"}

  test "accepts actors with valid IDs from supported assigns" do
    actor = %{id: "admin-1"}
    string_id_actor = %{"id" => "admin-2"}

    assert Authorization.actor(%{assigns: %{actor: actor}}) == {:ok, actor}
    assert Authorization.actor(%{assigns: %{current_user: actor}}) == {:ok, actor}
    assert Authorization.actor(%{assigns: %{"actor" => actor}}) == {:ok, actor}

    assert Authorization.actor(%{assigns: %{"current_user" => string_id_actor}}) ==
             {:ok, string_id_actor}
  end

  test "rejects missing, blank, malformed, and NUL actor IDs" do
    frames = [
      %{},
      %{assigns: %{}},
      %{assigns: %{actor: nil}},
      %{assigns: %{actor: %{}}},
      %{assigns: %{actor: %{id: nil}}},
      %{assigns: %{actor: %{id: ""}}},
      %{assigns: %{actor: %{id: " \t\n"}}},
      %{assigns: %{actor: %{id: "admin\0id"}}},
      %{assigns: %{actor: %{id: <<255>>}}},
      %{assigns: %{actor: %{id: 123}}}
    ]

    for frame <- frames do
      assert Authorization.actor(frame) == @unauthorized
    end
  end

  test "falls through a malformed actor assignment to a valid current user" do
    current_user = %{id: "admin-1"}

    assert Authorization.actor(%{
             assigns: %{actor: %{id: nil}, current_user: current_user}
           }) == {:ok, current_user}
  end
end
