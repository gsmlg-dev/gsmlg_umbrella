defmodule GSMLG.AdminWeb.ScoutFetchControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server
  alias GSMLG.Scout.Server.ResultHandler

  setup do
    previous_publisher = Application.get_env(:gsmlg_scout_server, :job_publisher)
    previous_test_pid = Application.get_env(:gsmlg_scout_server, :test_pid)
    previous_dns_resolver = Application.get_env(:gsmlg_scout, :dns_resolver)
    previous_settings = Application.get_env(:gsmlg_scout, :settings)

    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.Publisher)
    Application.put_env(:gsmlg_scout_server, :test_pid, self())
    Application.put_env(:gsmlg_scout, :dns_resolver, __MODULE__.PublicResolver)

    reset_scout_state()

    on_exit(fn ->
      restore_env(:gsmlg_scout_server, :job_publisher, previous_publisher)
      restore_env(:gsmlg_scout_server, :test_pid, previous_test_pid)
      restore_env(:gsmlg_scout, :dns_resolver, previous_dns_resolver)
      restore_env(:gsmlg_scout, :settings, previous_settings)
      reset_scout_state()
    end)

    :ok
  end

  test "fetch API requires admin bearer authentication", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/api/scout/fetch", %{url: "https://example.com/docs"})

    assert json_response(conn, 401)["message"] =~ "no_resource"
  end

  test "async create accepts a fetch job", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch", %{url: "https://example.com/docs"})

    assert %{"job_id" => job_id, "status" => "queued"} = json_response(conn, 202)
    assert ["job_id", "status"] = conn.resp_body |> Jason.decode!() |> Map.keys() |> Enum.sort()
    assert {:ok, %{job_id: ^job_id}} = Server.get_fetch(job_id)
  end

  test "sync returns a successful fetch result", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch/sync", %{url: "https://example.com/docs"})

    assert %{
             "ok" => true,
             "markdown" => markdown,
             "url" => "https://example.com/docs"
           } = json_response(conn, 200)

    assert markdown =~ "# Example Documentation"
  end

  test "sync returns 422 for a completed failed fetch result", %{conn: conn} do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.FailingPublisher)

    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch/sync", %{url: "https://example.com/fails"})

    assert %{
             "ok" => false,
             "error" => %{"type" => "fetch_failed", "message" => "upstream failed"}
           } = json_response(conn, 422)
  end

  test "sync returns 504 for expected fetch timeouts", %{conn: conn} do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.NoResultPublisher)

    Application.put_env(:gsmlg_scout, :settings, %{
      "general" => %{"request_timeout_ms" => 10},
      "fetch" => %{"default_timeout_ms" => 20, "max_timeout_ms" => 50}
    })

    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch/sync", %{
        url: "https://example.com/timeout",
        timeout_ms: 20
      })

    assert %{"error" => %{"type" => "timeout", "message" => "fetch timed out"}} =
             json_response(conn, 504)
  end

  test "sync returns 504 for completed timeout results", %{conn: conn} do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.TimeoutPublisher)

    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch/sync", %{url: "https://example.com/agent-timeout"})

    assert %{
             "ok" => false,
             "error" => %{"type" => "timeout", "message" => "agent fetch timed out"}
           } = json_response(conn, 504)
  end

  test "show returns not found for an unknown fetch job", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> get(~p"/api/scout/fetch/missing-job")

    assert %{"error" => %{"type" => "not_found"}} = json_response(conn, 404)
  end

  test "invalid_url and blocked_target errors return 422", %{conn: conn} do
    conn =
      conn
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch", %{url: ""})

    assert %{"error" => %{"type" => "invalid_url"}} = json_response(conn, 422)

    conn =
      Phoenix.ConnTest.build_conn()
      |> authenticated_conn()
      |> post(~p"/api/scout/fetch", %{url: "http://127.0.0.1:4000"})

    assert %{"error" => %{"type" => "blocked_target"}} = json_response(conn, 422)
  end

  defp authenticated_conn(conn) do
    unique = System.unique_integer([:positive])

    user =
      user_fixture(%{
        email: "scout-api-#{unique}@example.test",
        username: "scout_api_#{unique}"
      })

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  defp reset_scout_state do
    GSMLG.Scout.Server.JobManager.reset()
    GSMLG.Scout.Server.AgentRegistry.reset()
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

  defmodule FailingPublisher do
    def publish_job(job) do
      Task.start(fn ->
        ResultHandler.handle_result(
          Result.failure(job, %{
            type: "fetch_failed",
            message: "upstream failed",
            retryable: false
          })
        )
      end)

      :ok
    end
  end

  defmodule NoResultPublisher do
    def publish_job(_job), do: :ok
  end

  defmodule TimeoutPublisher do
    def publish_job(job) do
      Task.start(fn ->
        ResultHandler.handle_result(
          Result.failure(job, %{
            type: "timeout",
            message: "agent fetch timed out",
            retryable: true
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
