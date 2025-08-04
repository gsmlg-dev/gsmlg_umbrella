defmodule GSMLG.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Task,
       fn _ ->
         GSMLG.Config.config()
         |> GSMLG.Config.Setup.setup()
       end},
      {GSMLG.SimpleCache, []},
      {GSMLG.AWS, []},
      {GSMLG.Nx, []},
      {Phoenix.SessionProcess.Supervisor, name: GSMLG.SessionProcess},
      # Start the Ecto repository
      GSMLG.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: GSMLG.PubSub, adapter: Phoenix.PubSub.PG2},
      {GSMLG.CommandPlatform.Supervisor, name: GSMLG.CommandPlatform.Supervisor},
      # Start distribute Node
      {Finch, name: GSMLG.Finch},
      GSMLG.WebPush.Subscriptions,
      {GSMLG.Node.Supervisor, name: GSMLG.Node.Supervisor},
      {GSMLG.Chess.Supervisor, name: GSMLG.Chess.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Supervisor)
  end
end
