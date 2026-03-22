defmodule GSMLG.Storage.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Load S3 config from DB into Application env at startup.
    # gsmlg (and thus Repo) starts before gsmlg_storage so this is safe.
    Task.start(fn -> GSMLG.Storage.load_config_from_db() end)

    children = [
      GSMLG.Storage.CleanupWorker
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: GSMLG.Storage.Supervisor
    )
  end
end
