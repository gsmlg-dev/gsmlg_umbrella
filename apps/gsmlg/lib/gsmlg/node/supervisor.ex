defmodule GSMLG.Node.Supervisor do
  use Supervisor
  alias GSMLG.Cluster
  alias GSMLG.Node.Self
  alias GSMLG.Node.Others

  def start_link(name: name) do
    Supervisor.start_link(__MODULE__, :ok, name: name)
  end

  @impl true
  def init(_) do
    children =
      [
        {Self, []},
        {Others, []}
      ] ++ Cluster.child_specs()

    Supervisor.init(children, strategy: :one_for_one)
  end
end
