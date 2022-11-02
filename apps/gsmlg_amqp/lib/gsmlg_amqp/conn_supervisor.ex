defmodule GSMLG_AMQP.ConnSupervisor do
  use DynamicSupervisor

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_child(name, url) do
    # spec = {GSMLG_AMQP.Consumer, [name: name, url: url]}
    spec = {GSMLG_AMQP.Consumer, [name: name, url: url]}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @impl true
  def init(init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      extra_arguments: [init_arg]
    )
  end
end
