defmodule GSMLG.Chess.Supervisor do
  use Supervisor
  alias GSMLG.Chess.Room

  def start_link(name: name) do
    Supervisor.start_link(name, :ok)
  end

  @impl Supervisor
  def init(_) do
    children = [
      {Room, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
