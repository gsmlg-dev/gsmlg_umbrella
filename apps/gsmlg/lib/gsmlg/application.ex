defmodule GSMLG.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Ensure configuration is loaded synchronously before starting any supervised processes
    # This prevents race conditions with database connections and other config-dependent services
    GSMLG.Config.config()
    |> GSMLG.Config.Setup.setup()

    children = [
      {GSMLG.SimpleCache, []},
      {GSMLG.AWS, []},
      # {GSMLG.Nx, []},
      {Phoenix.SessionProcess.Supervisor,
       [
         session_process: GSMLG.SessionProcess,
         max_sessions: 1_000_000,
         session_ttl: 1_440_000,
         rate_limit: 10_000
       ]},
      {Task.Supervisor, name: GSMLG.TaskSupervisor},
      # Start the Ecto repository
      GSMLG.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: GSMLG.PubSub, adapter: Phoenix.PubSub.PG2},
      {GSMLG.CommandPlatform.Supervisor, name: GSMLG.CommandPlatform.Supervisor},
      # Start distribute Node
      {Finch, name: GSMLG.Finch},
      GSMLG.WebPush.Subscriptions,
      {GSMLG.Node.Supervisor, name: GSMLG.Node.Supervisor},
      {GSMLG.Chess.Supervisor, name: GSMLG.Chess.Supervisor},
      GSMLG.SVG2React,
      GSMLG.SVG_Autocrop
      # Telemetry system starts automatically as an OTP application
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Supervisor)
  end
end
