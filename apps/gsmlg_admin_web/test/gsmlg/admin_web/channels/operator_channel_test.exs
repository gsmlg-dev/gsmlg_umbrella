defmodule GSMLG.AdminWeb.OperatorChannelTest do
  use GSMLG.AdminWeb.ChannelCase, async: false

  alias GSMLG.CommandPlatform.{AgentRegistry, PTYSessionRecord}

  setup do
    ensure_pty_table!()

    agent_id = "agent-#{System.unique_integer([:positive])}"
    session_id = "#{agent_id}-pty"

    :ok = AgentRegistry.register_agent(agent_id, self())

    :ok =
      PTYSessionRecord.write(%{
        session_id: session_id,
        agent_id: agent_id,
        command: "/bin/bash",
        dimensions: %{rows: 24, cols: 80},
        created_at: System.system_time(:millisecond),
        last_activity: System.system_time(:millisecond),
        state: :running,
        metadata: %{}
      })

    on_exit(fn ->
      AgentRegistry.unregister_agent(agent_id)
      PTYSessionRecord.delete(session_id)
    end)

    %{agent_id: agent_id, session_id: session_id}
  end

  test "routes terminal input and resize commands to the session agent", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    {:ok, _reply, socket} =
      GSMLG.AdminWeb.UserSocket
      |> socket("operator", %{user_id: "operator"})
      |> subscribe_and_join(
        GSMLG.AdminWeb.OperatorChannel,
        "operator:terminal:#{session_id}",
        %{"agent_id" => agent_id}
      )

    push(socket, "input", %{"data" => "whoami\n"})
    assert_receive {:send_input, ^session_id, "whoami\n"}

    push(socket, "resize", %{"rows" => 40, "cols" => 120})
    assert_receive {:resize_pty, ^session_id, 40, 120}
    assert_push "resized", %{rows: 40, cols: 120}
  end

  test "pushes PTY output from the tracked session topic", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    {:ok, _reply, _socket} =
      GSMLG.AdminWeb.UserSocket
      |> socket("operator", %{user_id: "operator"})
      |> subscribe_and_join(
        GSMLG.AdminWeb.OperatorChannel,
        "operator:terminal:#{session_id}",
        %{"agent_id" => agent_id}
      )

    Phoenix.PubSub.broadcast(GSMLG.PubSub, "pty_session:#{session_id}", {
      :pty_output,
      session_id,
      "hello from pty"
    })

    assert_push "output", %{data: encoded}
    assert Base.decode64!(encoded) == "hello from pty"
  end

  test "joins with agent_id while session tracking is still catching up", %{
    agent_id: agent_id,
    session_id: session_id
  } do
    PTYSessionRecord.delete(session_id)

    {:ok, reply, socket} =
      GSMLG.AdminWeb.UserSocket
      |> socket("operator", %{user_id: "operator"})
      |> subscribe_and_join(
        GSMLG.AdminWeb.OperatorChannel,
        "operator:terminal:#{session_id}",
        %{"agent_id" => agent_id}
      )

    assert reply.status == "connected"
    assert reply.session_info.agent_id == agent_id
    assert_receive {:attach_pty, ^session_id}

    push(socket, "input", %{"data" => "pwd\n"})
    assert_receive {:send_input, ^session_id, "pwd\n"}
  end

  defp ensure_pty_table! do
    :ok = :mnesia.start()
    :ok = PTYSessionRecord.create_table()
  end
end
