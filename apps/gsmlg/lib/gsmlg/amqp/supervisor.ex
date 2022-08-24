defmodule GSMLG.AMQP.Supervisor do
  use Supervisor
  alias GSMLG.AMQP.Consumer

  def start_link(name: name) do
    Supervisor.start_link(name, :ok)
  end

  @impl Supervisor
  def init(_) do
    children = [
      {Consumer, [:start]}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
