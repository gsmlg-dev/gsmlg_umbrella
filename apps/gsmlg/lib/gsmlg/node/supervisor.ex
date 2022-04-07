defmodule GSMLG.Node.Supervisor do
  use Supervisor
  # alias GSMLG.Node.Distributed
  alias GSMLG.Node.Self
  alias GSMLG.Node.Others

  def start_link(name: name) do
    Supervisor.start_link(name, :ok)
  end

  @impl true
  def init(_) do
    children = [
      {Self, []},
      {Others, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
