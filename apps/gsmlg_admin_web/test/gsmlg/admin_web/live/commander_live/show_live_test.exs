defmodule GSMLG.AdminWeb.CommanderLive.ShowLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.CommandPlatform.{AgentRegistry, PTYSessionRecord}

  @secret_key_base String.duplicate("c", 64)

  setup %{conn: conn} do
    ensure_pty_store!()

    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    agent_id = "agent-#{System.unique_integer([:positive])}"
    :ok = AgentRegistry.register_agent(agent_id, self())
    {:ok, _generation} = AgentRegistry.attach_terminal(agent_id, self(), {:legacy, self()})

    AgentRegistry.update_agent_info(agent_id, %{
      hostname: "shell-host",
      capabilities: ["pty", "shell", "resize"],
      version: "test"
    })

    wait_until(fn ->
      match?({:ok, %{info: %{hostname: "shell-host"}}}, AgentRegistry.find_agent(agent_id))
    end)

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
      AgentRegistry.unregister_agent(agent_id)
    end)

    %{conn: conn, agent_id: agent_id}
  end

  test "shell tab creates a tracked PTY session for the commander", %{
    conn: conn,
    agent_id: agent_id
  } do
    {:ok, view, _html} = live(conn, ~p"/commander/#{agent_id}/shell")

    html = render_async(view)
    assert html =~ "shell-host"
    assert has_element?(view, "button[phx-click='new_terminal']", "New Session")

    render_click(element(view, "button[phx-click='new_terminal']"))

    assert_receive {:create_pty,
                    %{
                      session_id: session_id,
                      command: "/bin/bash",
                      dimensions: %{rows: 24, cols: 80}
                    }}

    session = wait_until_session(session_id)
    assert session.agent_id == agent_id
    assert session.state == :initializing

    html = render(view)
    assert html =~ ~s(data-session-id="#{session_id}")
    assert html =~ ~s(data-agent-id="#{agent_id}")
  end

  test "overview page uses the commander name route", %{conn: conn, agent_id: agent_id} do
    {:ok, view, _html} = live(conn, ~p"/commander/#{agent_id}/overview")

    html = render_async(view)
    assert html =~ "shell-host"
    assert html =~ ~s(href="/commander/#{agent_id}/shell")
  end

  test "browser tab is shown only after browser.control/v1 is advertised", %{
    conn: conn,
    agent_id: agent_id
  } do
    {:ok, view, _html} = live(conn, ~p"/commander/#{agent_id}/overview")
    refute render_async(view) =~ ~s(id="commander-browser-tab")

    AgentRegistry.update_agent_info(agent_id, %{
      capability_descriptors: [%{id: "browser.control", version: 1}]
    })

    wait_until(fn ->
      case AgentRegistry.find_agent(agent_id) do
        {:ok, %{info: %{capability_descriptors: descriptors}}} -> descriptors != []
        _other -> false
      end
    end)

    send(view.pid, :commander_updates)

    assert render_async(view) =~ ~s(href="/commander/#{agent_id}/browser")
    assert has_element?(view, "#commander-browser-tab", "Browser")
  end

  test "browser tab rejects missing, string, or embedded descriptor versions", %{
    conn: conn,
    agent_id: agent_id
  } do
    {:ok, view, _html} = live(conn, ~p"/commander/#{agent_id}/overview")

    for descriptor <- [
          %{id: "browser.control"},
          %{id: "browser.control", version: "1"},
          %{id: "browser.control/v1", version: 1}
        ] do
      AgentRegistry.update_agent_info(agent_id, %{capability_descriptors: [descriptor]})
      send(view.pid, :commander_updates)
      refute render_async(view) =~ ~s(id="commander-browser-tab")
    end
  end

  test "list page includes connected command-platform agents", %{conn: conn, agent_id: agent_id} do
    {:ok, view, _html} = live(conn, ~p"/commander/list")

    html = render_async(view)
    assert html =~ "shell-host"
    assert html =~ ~s(href="/commander/#{agent_id}/overview")
    assert html =~ ~s(href="/commander/#{agent_id}/shell")
  end

  test "legacy commander root redirects to the list page", %{conn: conn} do
    conn = get(conn, ~p"/commander")

    assert redirected_to(conn) == ~p"/commander/list"
  end

  defp ensure_pty_store! do
    :ok = PTYSessionRecord.create_table()
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")

  defp wait_until_session(session_id, attempts \\ 20)

  defp wait_until_session(session_id, attempts) when attempts > 0 do
    case PTYSessionRecord.read(session_id) do
      {:ok, session} ->
        session

      _ ->
        Process.sleep(10)
        wait_until_session(session_id, attempts - 1)
    end
  end

  defp wait_until_session(_session_id, 0), do: flunk("session was not recorded before timeout")
end
