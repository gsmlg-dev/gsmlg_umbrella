defmodule GSMLGYellowDog.Application do
  @moduledoc """
  Example implementing GSMLGDNS.Server behaviour
  """
  use Application

  @impl true
  def start(_type, _args) do
    config = Application.get_env(:gsmlg_yellow_dog, GSMLGYellowDog.Server)
    port = Keyword.get(config, :port, 5353)

    children = [
      {GSMLGYellowDog.Server, [name: GSMLGYellowDog.Server, port: port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: GSMLGYellowDog.Supervisor)
  end
end
