defmodule GSMLG.AWS do
  @moduledoc """
  Documentation for `GSMLG.AWS`.
  """

  use Supervisor

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  @impl true
  def init(_arg) do
    children = [
      {Cachex, name: :aws_cache},
      {Finch, name: GSMLG.AWS.Finch}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
