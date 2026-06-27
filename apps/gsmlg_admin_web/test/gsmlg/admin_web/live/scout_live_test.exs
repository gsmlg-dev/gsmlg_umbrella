defmodule GSMLG.AdminWeb.ScoutLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server
  alias GSMLG.Scout.Server.{AgentRegistry, ResultHandler}

  @secret_key_base String.duplicate("b", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])
    previous_publisher = Application.get_env(:gsmlg_scout_server, :job_publisher)
    previous_test_pid = Application.get_env(:gsmlg_scout_server, :test_pid)
    previous_dns_resolver = Application.get_env(:gsmlg_scout, :dns_resolver)

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.Publisher)
    Application.put_env(:gsmlg_scout_server, :test_pid, self())
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.PublicResolver)

    reset_scout_state()
    Phoenix.PubSub.subscribe(GSMLG.PubSub, "gsmlg_scout:jobs")

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
      restore_env(:gsmlg_scout_server, :job_publisher, previous_publisher)
      restore_env(:gsmlg_scout_server, :test_pid, previous_test_pid)
      restore_env(:gsmlg_scout, :dns_resolver, previous_dns_resolver)
      reset_scout_state()
    end)

    %{conn: conn}
  end

  test "unauthenticated users cannot access the Scout dashboard", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn() |> with_secret_key_base()
    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/scout")
  end

  test "dashboard renders jobs and agent stats", %{conn: conn} do
    assert {:ok, %{job_id: job_id}} = Server.submit_fetch(%{"url" => "https://example.com/docs"})
    assert_job_status(job_id, "completed")

    AgentRegistry.update_heartbeat(%{
      agent_id: "agent-1",
      region: "iad",
      status: "healthy",
      running_jobs: 1,
      capacity: 3,
      version: "0.1.0"
    })

    {:ok, view, html} = live(conn, ~p"/scout")

    assert html =~ "Scout Dashboard"
    assert has_element?(view, "#scout-fetch-form")
    assert has_element?(view, "#scout-jobs")
    assert has_element?(view, "#scout-agents")
    assert has_element?(view, "#scout-job-#{job_id}", "https://example.com/docs")
    assert has_element?(view, "#scout-agent-agent-1", "agent-1")
    assert html =~ "1 jobs"
    assert html =~ "1 completed"
    assert html =~ "1 agents"
    assert html =~ "3 capacity"
  end

  test "submitting a fetch queues a job", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scout")

    html =
      render_submit(view, "submit_fetch", %{
        "fetch" => %{"url" => "https://example.com/from-live"}
      })

    assert html =~ "Fetch queued"
    assert_receive {:published, %{url: "https://example.com/from-live"}}
    assert [%{url: "https://example.com/from-live"}] = Server.list_fetches()
  end

  test "PubSub job and agent updates are reflected", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/scout")

    assert {:ok, %{job_id: job_id}} =
             Server.submit_fetch(%{"url" => "https://example.com/pubsub"})

    assert_job_status(job_id, "completed")

    AgentRegistry.update_heartbeat(%{
      "agent_id" => "agent-pubsub",
      "region" => "sfo",
      "status" => "healthy",
      "running_jobs" => 0,
      "capacity" => 2,
      "version" => "0.2.0"
    })

    assert render(view) =~ "https://example.com/pubsub"
    assert has_element?(view, "#scout-agent-agent-pubsub", "agent-pubsub")
    assert render(view) =~ "2 capacity"
  end

  test "markdown content is available in a DuskMoon modal for completed jobs", %{conn: conn} do
    assert {:ok, %{job_id: job_id}} = Server.submit_fetch(%{"url" => "https://example.com/docs"})
    assert_job_status(job_id, "completed")

    {:ok, view, html} = live(conn, ~p"/scout")

    assert has_element?(view, "#scout-job-#{job_id}", "Show content")
    assert has_element?(view, "el-dm-dialog#scout-job-content-#{job_id}[role='dialog']")
    assert has_element?(view, "#scout-job-content-#{job_id} el-dm-markdown")
    assert html =~ "# Example Documentation"
    assert html =~ "Fetched https://example.com/docs"
  end

  defp assert_job_status(job_id, expected) do
    receive do
      {:job_updated, %{job_id: ^job_id, status: ^expected} = job} ->
        job

      {:job_updated, %{job_id: ^job_id}} ->
        assert_job_status(job_id, expected)
    after
      1_000 -> flunk("expected job #{job_id} to reach #{expected}")
    end
  end

  defp reset_scout_state do
    GSMLG.Scout.Server.JobManager.reset()
    GSMLG.Scout.Server.AgentRegistry.reset()
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defmodule Publisher do
    def publish_job(job) do
      send(Application.fetch_env!(:gsmlg_scout_server, :test_pid), {:published, job})

      Task.start(fn ->
        markdown = "# Example Documentation\n\nFetched #{job.url}"

        ResultHandler.handle_result(
          Result.success(job, %{
            markdown: markdown,
            title: "Example Documentation",
            final_url: job.url,
            agent_id: "test-agent-1",
            duration_ms: 1,
            word_count: 4
          })
        )
      end)

      :ok
    end
  end

  defmodule PublicResolver do
    def getaddrs(_host, _family), do: {:ok, [{93, 184, 216, 34}]}
  end
end
