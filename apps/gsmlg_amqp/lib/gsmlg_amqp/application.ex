defmodule GSMLG_AMQP.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {GSMLG_AMQP.ConnSupervisor, name: GSMLG_AMQP.ConnSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLG_AMQP.Supervisor)
  end
end
