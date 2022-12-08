defmodule GSMLG.AMQP.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {GSMLG.AMQP.ConnSupervisor, name: GSMLG.AMQP.ConnSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG.AMQP.Supervisor)
  end
end
