defmodule GSMLG.Repo.Migrations.AddSessionOwnedBrowserArtifacts do
  use Ecto.Migration

  def change do
    alter table(:browser_artifacts) do
      modify :job_id, references(:browser_jobs, type: :binary_id, on_delete: :delete_all),
        null: true,
        from: {references(:browser_jobs, type: :binary_id, on_delete: :delete_all), null: false}

      add :session_id, references(:browser_sessions, type: :binary_id, on_delete: :delete_all)
    end

    create index(:browser_artifacts, [:session_id, :inserted_at])

    create constraint(:browser_artifacts, :browser_artifacts_exactly_one_owner_check,
             check: "(job_id IS NULL) <> (session_id IS NULL)"
           )
  end
end
