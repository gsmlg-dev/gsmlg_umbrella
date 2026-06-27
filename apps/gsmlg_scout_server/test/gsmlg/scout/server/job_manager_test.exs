defmodule GSMLG.Scout.Server.JobManagerTest do
  use ExUnit.Case, async: false

  alias GSMLG.Scout.Fetch.Result
  alias GSMLG.Scout.Server.ResultHandler

  setup context do
    previous_publisher = Application.get_env(:gsmlg_scout_server, :job_publisher)
    previous_settings = Application.get_env(:gsmlg_scout, :settings)
    previous_test_pid = Application.get_env(:gsmlg_scout_server, :test_pid)

    reset_server_state()

    if context[:without_test_publisher] do
      Application.delete_env(:gsmlg_scout_server, :job_publisher)
    else
      Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.Publisher)
    end

    on_exit(fn ->
      restore_env(:job_publisher, previous_publisher)
      restore_env(:test_pid, previous_test_pid)
      restore_scout_env(:settings, previous_settings)
    end)

    :ok
  end

  test "resets jobs and agents between tests" do
    assert {:ok, _job} =
             GSMLG.Scout.Server.submit_fetch(%{"url" => "https://example.com/reset"})

    GSMLG.Scout.Server.AgentRegistry.update_heartbeat(%{
      "agent_id" => "agent-reset",
      "status" => "healthy"
    })

    assert :ok = GSMLG.Scout.Server.JobManager.reset()
    assert :ok = GSMLG.Scout.Server.AgentRegistry.reset()
    assert [] = GSMLG.Scout.Server.list_fetches()
    assert [] = GSMLG.Scout.Server.list_agents()
  end

  test "submits a fetch job and stores the markdown result from an agent" do
    Phoenix.PubSub.subscribe(GSMLG.PubSub, "gsmlg_scout:jobs")

    assert {:ok, %{job_id: job_id, status: "queued"}} =
             GSMLG.Scout.Server.submit_fetch(%{"url" => "https://example.com/docs"})

    completed = assert_job_status(job_id, "completed")

    assert completed.result.markdown =~ "# Example Documentation"
    assert completed.result.word_count > 0

    assert {:ok, stored} = GSMLG.Scout.Server.get_fetch(job_id)
    assert stored.status == "completed"
  end

  test "runs a synchronous fetch by dispatching and waiting for a result" do
    assert {:ok, result} = GSMLG.Scout.Server.fetch_sync(%{"url" => "https://example.com/sync"})

    assert result.ok
    assert result.markdown =~ "https://example.com/sync"
  end

  @tag :without_test_publisher
  test "returns an explicit error when RabbitMQ transport is disabled" do
    Phoenix.PubSub.subscribe(GSMLG.PubSub, "gsmlg_scout:jobs")

    assert {:error, %{type: "transport_disabled", message: message, retryable: false} = error} =
             GSMLG.Scout.Server.submit_fetch(%{"url" => "https://example.com/no-transport"})

    assert message == "Scout RabbitMQ transport is disabled"

    assert_receive {:job_updated, %{job_id: job_id, status: "queued"}}
    assert_receive {:job_updated, %{job_id: ^job_id, status: "failed", error: ^error}}
  end

  test "returns retry dispatch errors to synchronous callers promptly" do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.RetryThenFailPublisher)
    Application.put_env(:gsmlg_scout_server, :test_pid, self())

    Application.put_env(:gsmlg_scout, :settings, %{
      "general" => %{"request_timeout_ms" => 200},
      "fetch" => %{
        "default_timeout_ms" => 200,
        "retry" => %{
          "max_attempts" => 2,
          "base_backoff_ms" => 1,
          "max_backoff_ms" => 1,
          "jitter" => false
        }
      }
    })

    assert {:error,
            %{
              type: "transport_disabled",
              message: "Scout RabbitMQ transport is disabled",
              retryable: false
            }} =
             GSMLG.Scout.Server.fetch_sync(%{
               "url" => "https://example.com/retry",
               "timeout_ms" => 200
             })

    assert_received {:published_attempt, 1}
    assert_received {:published_attempt, 2}
  end

  test "wraps publisher exceptions as structured dispatch failures" do
    Application.put_env(:gsmlg_scout_server, :job_publisher, __MODULE__.RaisingPublisher)

    assert {:error, %{type: "dispatch_failed", message: message, retryable: true}} =
             GSMLG.Scout.Server.submit_fetch(%{"url" => "https://example.com/raise"})

    assert message =~ "publisher exploded"
  end

  test "lists agent heartbeats" do
    GSMLG.Scout.Server.AgentRegistry.update_heartbeat(%{
      "agent_id" => "agent-1",
      "region" => "test",
      "status" => "healthy",
      "running_jobs" => 0,
      "capacity" => 1,
      "version" => "0.1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    })

    assert [%{agent_id: "agent-1", status: "healthy"}] = GSMLG.Scout.Server.list_agents()
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

  defp restore_env(key, nil), do: Application.delete_env(:gsmlg_scout_server, key)
  defp restore_env(key, value), do: Application.put_env(:gsmlg_scout_server, key, value)

  defp restore_scout_env(key, nil), do: Application.delete_env(:gsmlg_scout, key)
  defp restore_scout_env(key, value), do: Application.put_env(:gsmlg_scout, key, value)

  defp reset_server_state do
    :ok = GSMLG.Scout.Server.JobManager.reset()
    :ok = GSMLG.Scout.Server.AgentRegistry.reset()
  end

  defmodule Publisher do
    def publish_job(job) do
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

  defmodule RetryThenFailPublisher do
    alias GSMLG.Scout.Fetch.Result
    alias GSMLG.Scout.Server.ResultHandler

    def publish_job(%{attempt: 1} = job) do
      send(test_pid(), {:published_attempt, 1})

      Task.start(fn ->
        ResultHandler.handle_result(
          Result.failure(job, %{
            type: "temporary_network_failure",
            message: "temporary failure",
            retryable: true
          })
        )
      end)

      :ok
    end

    def publish_job(%{attempt: 2}) do
      send(test_pid(), {:published_attempt, 2})

      {:error,
       %{
         type: "transport_disabled",
         message: "Scout RabbitMQ transport is disabled",
         retryable: false
       }}
    end

    defp test_pid do
      Application.fetch_env!(:gsmlg_scout_server, :test_pid)
    end
  end

  defmodule RaisingPublisher do
    def publish_job(_job), do: raise("publisher exploded")
  end
end
