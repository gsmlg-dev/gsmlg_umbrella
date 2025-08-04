defmodule GSMLG.Config.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {GSMLG.Config, []}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.Config.Supervisor)
  end
end
