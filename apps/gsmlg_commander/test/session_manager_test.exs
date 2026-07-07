defmodule GSMLG.Commander.SessionManagerTest do
  use ExUnit.Case, async: false

  alias GSMLG.Commander.SessionManager

  test "lists local PTY sessions through the agent local registry" do
    start_supervised!({Registry, keys: :unique, name: GSMLG.Commander.LocalSessionRegistry})
    start_supervised!({SessionManager, []})

    assert SessionManager.list_sessions() == []
  end
end
