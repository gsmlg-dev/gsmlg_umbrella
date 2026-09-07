defmodule GSMLG.Repo.Migrations.CreateBrowserControlTables do
  use Ecto.Migration

  def change do
    create table(:browser_nodes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :commander_id, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :default_backend, :string, null: false
      add :status, :string, null: false, default: "offline"
      add :capabilities, {:array, :map}, null: false, default: []
      add :limits, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec
      add :last_error, :map
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:browser_nodes, [:commander_id])

    create constraint(:browser_nodes, :browser_nodes_status_check,
             check: "status IN ('online', 'degraded', 'offline', 'disabled')"
           )

    create table(:browser_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :node_id, references(:browser_nodes, type: :binary_id, on_delete: :delete_all),
        null: false

      add :external_id, :string, null: false
      add :name, :string, null: false
      add :backend, :string, null: false
      add :enabled, :boolean, null: false, default: true
      add :is_default, :boolean, null: false, default: false
      add :runtime_status, :string, null: false, default: "unknown"
      add :automation_status, :string, null: false, default: "available"
      add :locale, :string
      add :timezone, :string
      add :screen, :map, null: false, default: %{}
      add :policy, :map, null: false, default: %{}
      add :last_seen_at, :utc_datetime_usec
      add :last_error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:browser_profiles, [:node_id, :external_id])

    create unique_index(:browser_profiles, [:node_id],
             where: "is_default",
             name: :browser_profiles_one_default_per_node_index
           )

    create constraint(:browser_profiles, :browser_profiles_runtime_status_check,
             check: "runtime_status IN ('unknown', 'running', 'stopped', 'unavailable')"
           )

    create constraint(:browser_profiles, :browser_profiles_automation_status_check,
             check: "automation_status IN ('available', 'leased', 'manual', 'disabled')"
           )

    create table(:browser_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :node_id, references(:browser_nodes, type: :binary_id, on_delete: :restrict),
        null: false

      add :profile_id, references(:browser_profiles, type: :binary_id, on_delete: :restrict),
        null: false

      add :remote_session_id, :binary_id
      add :lease_id, :binary_id
      add :mode, :string, null: false
      add :status, :string, null: false
      add :origin_policy, :map, null: false, default: %{}
      add :revision, :bigint, null: false, default: 0

      add :owner_actor_id, references(:users, type: :string, on_delete: :restrict), null: false
      add :last_seen_at, :utc_datetime_usec
      add :expires_at, :utc_datetime_usec, null: false
      add :error, :map

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:browser_sessions, [:remote_session_id],
             where: "remote_session_id IS NOT NULL"
           )

    create index(:browser_sessions, [:owner_actor_id, :status])
    create index(:browser_sessions, [:profile_id, :status])

    create constraint(:browser_sessions, :browser_sessions_mode_check,
             check: "mode IN ('automation', 'manual')"
           )

    create constraint(:browser_sessions, :browser_sessions_status_check,
             check:
               "status IN ('opening', 'ready', 'acting', 'waiting', 'waiting_human', 'closing', 'closed', 'orphaned', 'failed')"
           )

    create constraint(:browser_sessions, :browser_sessions_revision_check, check: "revision >= 0")

    create table(:browser_jobs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :node_id, references(:browser_nodes, type: :binary_id, on_delete: :restrict),
        null: false

      add :profile_id, references(:browser_profiles, type: :binary_id, on_delete: :restrict),
        null: false

      add :session_id, references(:browser_sessions, type: :binary_id, on_delete: :nilify_all)
      add :remote_execution_id, :binary_id
      add :workflow, :string, null: false
      add :workflow_version, :integer, null: false
      add :status, :string, null: false
      add :phase, :string
      add :input, :map, null: false, default: %{}
      add :output_formats, {:array, :string}, null: false, default: []
      add :idempotency_key, :string, null: false
      add :attempt, :integer, null: false, default: 1

      add :previous_job_id,
          references(:browser_jobs, type: :binary_id, on_delete: :restrict)

      add :last_remote_sequence, :bigint, null: false, default: 0
      add :control_keys, :map, null: false, default: %{}
      add :result, :map
      add :error, :map

      add :requested_by_actor_id, references(:users, type: :string, on_delete: :restrict),
        null: false

      add :deadline_at, :utc_datetime_usec, null: false
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:browser_jobs, [:requested_by_actor_id, :idempotency_key],
             name: :browser_jobs_actor_idempotency_index
           )

    create unique_index(:browser_jobs, [:remote_execution_id],
             where: "remote_execution_id IS NOT NULL"
           )

    create unique_index(:browser_jobs, [:previous_job_id],
             where: "previous_job_id IS NOT NULL",
             name: :browser_jobs_linear_retry_index
           )

    create index(:browser_jobs, [:requested_by_actor_id, :status])
    create index(:browser_jobs, [:status, :updated_at])

    create constraint(:browser_jobs, :browser_jobs_workflow_version_check,
             check: "workflow_version > 0"
           )

    create constraint(:browser_jobs, :browser_jobs_status_check,
             check:
               "status IN ('queued', 'dispatching', 'accepted', 'unknown', 'running', 'waiting_human', 'collecting_artifacts', 'completed', 'failed', 'cancelled')"
           )

    create constraint(:browser_jobs, :browser_jobs_attempt_lineage_check,
             check:
               "(attempt = 1 AND previous_job_id IS NULL) OR (attempt > 1 AND previous_job_id IS NOT NULL)"
           )

    create constraint(:browser_jobs, :browser_jobs_remote_sequence_check,
             check: "last_remote_sequence >= 0"
           )

    create table(:browser_job_events, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :job_id, references(:browser_jobs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :remote_execution_id, :binary_id, null: false
      add :sequence, :bigint, null: false
      add :event, :string, null: false
      add :phase, :string
      add :metadata, :map, null: false, default: %{}
      add :occurred_at, :utc_datetime_usec
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:browser_job_events, [:remote_execution_id, :sequence])
    create unique_index(:browser_job_events, [:job_id, :sequence])
    create index(:browser_job_events, [:job_id, :inserted_at])

    create constraint(:browser_job_events, :browser_job_events_sequence_check,
             check: "sequence > 0"
           )

    create constraint(:browser_job_events, :browser_job_events_event_check,
             check:
               "event IN ('workflow.accepted', 'workflow.started', 'workflow.phase_changed', 'intervention.required', 'intervention.cleared', 'artifact.available', 'result.available', 'workflow.failed', 'workflow.cancelled', 'workflow.completed')"
           )

    create table(:browser_artifacts, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :job_id, references(:browser_jobs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :kind, :string, null: false
      add :mime, :string, null: false
      add :filename, :string, null: false
      add :size, :bigint, null: false
      add :sha256, :string, size: 64, null: false
      add :transfer_mode, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :storage_type, :string
      add :storage_ref, :binary_id
      add :inline_content, :binary
      add :metadata, :map, null: false, default: %{}
      add :upload_token_digest, :binary
      add :upload_expires_at, :utc_datetime_usec
      add :verified_at, :utc_datetime_usec
      add :rejected_at, :utc_datetime_usec
      add :ack_status, :string, null: false, default: "not_ready"
      add :ack_attempts, :integer, null: false, default: 0
      add :acked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:browser_artifacts, [:job_id, :inserted_at])

    create constraint(:browser_artifacts, :browser_artifacts_kind_check,
             check:
               "kind IN ('report.markdown', 'report.html', 'report.json', 'sources.json', 'observation.json', 'screenshot.png', 'download', 'failure-diagnostic.json')"
           )

    create constraint(:browser_artifacts, :browser_artifacts_transfer_mode_check,
             check: "transfer_mode IN ('inline', 'signed_upload', 'remote_pending')"
           )

    create constraint(:browser_artifacts, :browser_artifacts_status_check,
             check: "status IN ('pending', 'uploading', 'verified', 'rejected')"
           )

    create constraint(:browser_artifacts, :browser_artifacts_size_check, check: "size >= 0")

    create constraint(:browser_artifacts, :browser_artifacts_sha256_check,
             check: "sha256 ~ '^[0-9a-f]{64}$'"
           )

    create constraint(:browser_artifacts, :browser_artifacts_ack_status_check,
             check: "ack_status IN ('not_ready', 'pending', 'acked')"
           )

    create constraint(:browser_artifacts, :browser_artifacts_ack_attempts_check,
             check: "ack_attempts >= 0"
           )
  end
end
