defmodule GSMLG.BrowserAgent.Supervisor do
  @moduledoc false

  use Supervisor

  alias GSMLG.BrowserAgent.{
    Capability,
    EventDelivery,
    Journal,
    ManagerMonitor,
    ProfileLeaseServer,
    Settings,
    WorkflowSupervisor
  }

  alias GSMLG.BrowserAgent.SessionSupervisor
  alias GSMLG.BrowserAgent.ArtifactOutbox.Recovery, as: ArtifactRecovery

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    settings = Keyword.get_lazy(opts, :settings, &Settings.load!/0)
    Supervisor.init(children(settings), strategy: :one_for_one)
  end

  defp children(%Settings{enabled: false}), do: []

  defp children(%Settings{} = settings) do
    [
      {Finch,
       name: GSMLG.BrowserAgent.Finch,
       pools: %{
         default: [
           conn_opts: [transport_opts: [timeout: settings.manager_connect_timeout_ms]]
         ]
       }},
      {Journal,
       path: Path.join(settings.state_dir, "journal.dets"),
       journal_terminal_max_records: settings.journal_terminal_max_records,
       journal_terminal_max_age_ms: settings.journal_terminal_max_age_ms,
       journal_terminal_max_bytes: settings.journal_terminal_max_bytes,
       journal_recovery_scan_max_records: settings.journal_recovery_scan_max_records},
      {ArtifactRecovery, state_dir: settings.state_dir},
      {ProfileLeaseServer, default_ttl_ms: settings.lease_ttl_ms},
      {ManagerMonitor, settings: settings, interval_ms: settings.monitor_interval_ms},
      {SessionSupervisor,
       settings: settings,
       journal: Journal,
       lease_server: ProfileLeaseServer,
       registry_name: GSMLG.BrowserAgent.SessionRegistry,
       runner_supervisor_name: GSMLG.BrowserAgent.SessionRunnerSupervisor,
       cdp_supervisor_name: GSMLG.BrowserAgent.CDPSupervisor},
      {WorkflowSupervisor,
       journal: Journal,
       session_api: GSMLG.BrowserAgent.Session,
       session_supervisor: SessionSupervisor,
       registry_name: GSMLG.BrowserAgent.WorkflowRegistry,
       runner_supervisor_name: GSMLG.BrowserAgent.WorkflowRunnerSupervisor,
       max_children: settings.max_concurrent_workflows,
       max_observation_bytes: settings.max_observation_bytes,
       max_artifact_bytes: settings.max_artifact_bytes,
       state_dir: settings.state_dir},
      {EventDelivery, journal: Journal, connection: GSMLG.Commander.Connection},
      {Capability,
       settings: settings,
       workflow_api: WorkflowSupervisor,
       workflow_supervisor: WorkflowSupervisor}
    ]
  end
end
