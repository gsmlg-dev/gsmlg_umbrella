defmodule GSMLG.CommandPlatform.Supervisor do
  use Supervisor

  def start_link(name: name) do
    Supervisor.start_link(name, :ok)
  end

  @impl true
  def init(_) do
    children = [
      {GSMLG.CommandPlatform.Agent, %{commanders: []}},
      {GSMLG.CommandPlatform, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
