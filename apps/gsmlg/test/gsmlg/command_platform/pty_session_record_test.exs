defmodule GSMLG.CommandPlatform.PTYSessionRecordTest do
  use ExUnit.Case, async: false

  alias GSMLG.CommandPlatform.PTYSessionRecord

  setup do
    :ok = PTYSessionRecord.create_table()

    session_id = "session-#{System.unique_integer([:positive])}"
    agent_id = "agent-#{System.unique_integer([:positive])}"

    on_exit(fn -> PTYSessionRecord.delete(session_id) end)

    %{agent_id: agent_id, session_id: session_id}
  end

  test "stores, lists, reads, and deletes PTY sessions without Mnesia", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    session = %{
      session_id: session_id,
      agent_id: agent_id,
      command: "/bin/bash",
      dimensions: %{rows: 24, cols: 80},
      created_at: 1_720_000_000_000,
      last_activity: 1_720_000_000_001,
      state: :running,
      metadata: %{source: "test"}
    }

    assert :ok = PTYSessionRecord.write(session)

    assert {:ok,
            %PTYSessionRecord{
              session_id: ^session_id,
              agent_id: ^agent_id,
              state: :running,
              metadata: %{source: "test"}
            }} = PTYSessionRecord.read(session_id)

    assert [%{session_id: ^session_id}] = PTYSessionRecord.list(agent_id: agent_id)

    assert %{session_id: ^session_id} =
             Enum.find(PTYSessionRecord.list(state: :running), &(&1.session_id == session_id))

    assert PTYSessionRecord.count(agent_id: agent_id) == 1

    assert :ok = PTYSessionRecord.delete(session_id)
    assert {:error, :not_found} = PTYSessionRecord.read(session_id)
  end

  test "cleans up old closed sessions", %{agent_id: agent_id, session_id: session_id} do
    assert :ok =
             PTYSessionRecord.write(%{
               session_id: session_id,
               agent_id: agent_id,
               command: "/bin/bash",
               dimensions: %{rows: 24, cols: 80},
               created_at: 1,
               last_activity: 1,
               state: :closed,
               metadata: %{}
             })

    assert :ok = PTYSessionRecord.cleanup_old_sessions(1)
    assert {:error, :not_found} = PTYSessionRecord.read(session_id)
  end
end
