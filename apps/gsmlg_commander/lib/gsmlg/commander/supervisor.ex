defmodule GSMLG.Commander.Supervior do
  # Automatically defines child_spec/1
  use Supervisor
  require Logger

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    socket_opts = GSMLG.Commander.socket_opts()
    Logger.info("start GSMLG.Commander.Supervior: " <> inspect(socket_opts))

    children = [
      {PhoenixClient.Socket, {socket_opts, name: GSMLG.Commander.Socket}},
      {GSMLG.Commander.GreatHall, []}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
