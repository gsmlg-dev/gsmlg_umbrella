defmodule GSMLG.Storage.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load S3 config from DB into Application env synchronously before
    # starting children so CleanupWorker sees the correct credentials/intervals.
    # gsmlg (and thus Repo) starts before gsmlg_storage, so Repo is ready.
    GSMLG.Storage.load_config_from_db()

    children = [
      GSMLG.Storage.CleanupWorker
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GSMLG.Storage.Supervisor
    )
  end
end
