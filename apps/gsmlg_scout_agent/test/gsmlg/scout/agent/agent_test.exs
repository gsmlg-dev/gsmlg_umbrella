defmodule GSMLG.Scout.AgentTest do
  use ExUnit.Case, async: false

  setup do
    previous_settings = Application.get_env(:gsmlg_scout, :settings)

    Application.put_env(:gsmlg_scout, :settings, %{
      agent: %{
        id: "test-agent-1",
        capacity: 4,
        browser_instances: 2
      }
    })

    on_exit(fn ->
      case previous_settings do
        nil -> Application.delete_env(:gsmlg_scout, :settings)
        settings -> Application.put_env(:gsmlg_scout, :settings, settings)
      end
    end)
  end

  test "fetches a job through the Lightpanda pool" do
    assert {:ok, job} = GSMLG.Scout.Fetch.Job.new(%{"url" => "https://example.com/docs"})

    result = GSMLG.Scout.Agent.fetch(job)

    assert result.ok
    assert result.markdown =~ "# Example Documentation"
    assert result.agent_id == "test-agent-1"
  end

  test "reports agent status from settings and pool state" do
    assert %{
             agent_id: "test-agent-1",
             status: "healthy",
             running_jobs: 0,
             capacity: 4
           } = GSMLG.Scout.Agent.status()
  end

  test "application startup gate does not call Mix.env at runtime" do
    source =
      __DIR__
      |> Path.join("../../../../lib/gsmlg/scout/agent/application.ex")
      |> Path.expand()
      |> File.read!()

    refute source =~ "Mix.env"
  end

  test "Lightpanda CLI returns structured error when task supervisor is unavailable" do
    stop_task_supervisor()
    executable = System.find_executable("echo") || System.find_executable("printf")

    assert is_binary(executable)

    assert {:error, %{type: "agent_not_started", retryable: true}} =
             GSMLG.Scout.Agent.Lightpanda.CLI.fetch("https://example.com", %{
               "lightpanda_path" => executable
             })
  end

  test "Lightpanda pool uses configured browser_instances for pool pressure" do
    previous_adapter = Application.get_env(:gsmlg_scout_agent, :lightpanda_adapter)

    Application.put_env(:gsmlg_scout_agent, :test_pid, self())
    Application.put_env(:gsmlg_scout_agent, :lightpanda_adapter, __MODULE__.BlockingLightpanda)

    Application.put_env(:gsmlg_scout, :settings, %{
      agent: %{id: "test-agent-1", browser_instances: 1}
    })

    restart_pool()

    on_exit(fn ->
      case previous_adapter do
        nil -> Application.delete_env(:gsmlg_scout_agent, :lightpanda_adapter)
        adapter -> Application.put_env(:gsmlg_scout_agent, :lightpanda_adapter, adapter)
      end

      Application.delete_env(:gsmlg_scout_agent, :test_pid)
      restart_pool()
    end)

    task_1 =
      Task.async(fn ->
        GSMLG.Scout.Agent.LightpandaPool.fetch("https://example.com/one", %{"timeout_ms" => 1_000})
      end)

    assert_receive {:blocking_fetch_started, first_pid, "https://example.com/one"}

    task_2 =
      Task.async(fn ->
        GSMLG.Scout.Agent.LightpandaPool.fetch("https://example.com/two", %{"timeout_ms" => 1_000})
      end)

    refute_receive {:blocking_fetch_started, _pid, _url}, 100

    send(first_pid, :release_fetch)

    assert_receive {:blocking_fetch_started, second_pid, "https://example.com/two"}

    send(second_pid, :release_fetch)

    assert {:ok, %{status_code: 200}} = Task.await(task_1)
    assert {:ok, %{status_code: 200}} = Task.await(task_2)
  end

  defp stop_task_supervisor do
    case Process.whereis(GSMLG.Scout.Agent.TaskSupervisor) do
      nil ->
        :ok

      _pid ->
        assert :ok =
                 Supervisor.terminate_child(
                   GSMLG.Scout.Agent.Supervisor,
                   GSMLG.Scout.Agent.TaskSupervisor
                 )

        on_exit(fn ->
          case Supervisor.restart_child(
                 GSMLG.Scout.Agent.Supervisor,
                 GSMLG.Scout.Agent.TaskSupervisor
               ) do
            {:ok, _pid} -> :ok
            {:error, :running} -> :ok
            {:error, :not_found} -> :ok
          end
        end)
    end
  end

  defp restart_pool do
    case Process.whereis(GSMLG.Scout.Agent.LightpandaPool) do
      nil ->
        :ok

      _pid ->
        assert :ok =
                 Supervisor.terminate_child(
                   GSMLG.Scout.Agent.Supervisor,
                   GSMLG.Scout.Agent.LightpandaPool
                 )
    end

    case Supervisor.restart_child(GSMLG.Scout.Agent.Supervisor, GSMLG.Scout.Agent.LightpandaPool) do
      {:ok, _pid} -> :ok
      {:error, :running} -> :ok
    end
  end

  defmodule BlockingLightpanda do
    @behaviour GSMLG.Scout.Agent.Lightpanda

    @impl true
    def fetch(url, _opts) do
      send(Application.fetch_env!(:gsmlg_scout_agent, :test_pid), {
        :blocking_fetch_started,
        self(),
        url
      })

      receive do
        :release_fetch ->
          {:ok,
           %{
             final_url: url,
             title: "Blocked",
             markdown: "# Blocked",
             status_code: 200
           }}
      after
        1_000 ->
          {:error, %{type: "test_timeout", message: "release not received", retryable: false}}
      end
    end
  end
end
