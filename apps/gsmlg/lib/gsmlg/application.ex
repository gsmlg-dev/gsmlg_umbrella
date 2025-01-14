defmodule GSMLG.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {GSMLG.SimpleCache, []},
      {Cachex, name: :aws_cache},
      # Start the Ecto repository
      GSMLG.Repo,
      # Start the PubSub system
      {Phoenix.PubSub, name: GSMLG.PubSub, adapter: Phoenix.PubSub.PG2},
      {GSMLG.CommandPlatform.Supervisor, name: GSMLG.CommandPlatform.Supervisor},
      # Start distribute Node
      {GSMLG.Node.Supervisor, name: GSMLG.Node.Supervisor},
      {GSMLG.Chess.Supervisor, name: GSMLG.Chess.Supervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Supervisor)
  end
end
