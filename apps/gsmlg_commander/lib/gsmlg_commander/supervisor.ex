defmodule GSMLGCommander.Supervior do
  # Automatically defines child_spec/1
  use Supervisor
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    socket_opts = GSMLGCommander.socket_opts()
    Logger.info("start GSMLGCommander.Supervior: " <> inspect(socket_opts))

    children = [
      {PhoenixClient.Socket, {socket_opts, name: GSMLGCommander.Socket}},
      {GSMLGCommander.GreatHall, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
