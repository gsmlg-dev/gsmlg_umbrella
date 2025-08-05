defmodule GSMLG.Commander.GreatHall do
  use GenServer
  require Logger

  alias PhoenixClient.{Channel, Message}

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  push event to server
  """
  @spec push(String.t(), any) :: {:ok, term} | {:error, term}
  def push(topic, message) do
    chn = get_state() |> Map.get(:office)
    PhoenixClient.Channel.push(chn, topic, message)
  end

  @doc """
  push event to server async
  """
  @spec push_async(String.t(), any) :: :ok | :error
  def push_async(topic, message) do
    chn = get_state() |> Map.get(:office)
    PhoenixClient.Channel.push_async(chn, topic, message)
  end

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %{peons: [], jobs: [], office: nil}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    case Channel.join(GSMLG.Commander.Socket, "command_platform") do
      {:ok, response, channel} ->
        Logger.info("GreatHall join success: " <> inspect(response))
        state = state |> Map.put(:office, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("GreatHall join failed: " <> inspect(reason))
        Process.send_after(__MODULE__, :join, 15_000)
        Logger.debug("GreatHall join failed: " <> "rejoin after 15 seconds.")
        {:noreply, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:join, state) do
    case Channel.join(GSMLG.Commander.Socket, "command_platform") do
      {:ok, response, channel} ->
        Logger.info("GreatHall join success: " <> inspect(response))
        state = state |> Map.put(:office, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("GreatHall join failed: " <> inspect(reason))
        Process.send_after(__MODULE__, :join, 15_000)
        Logger.debug("GreatHall join failed: " <> "rejoin after 15 seconds.")
        {:noreply, state}
    end
  end

  def handle_info(:ping, state) do
    chn = state |> Map.get(:office)
    Process.send_after(__MODULE__, :ping, 60_000)

    reply =
      PhoenixClient.Channel.push(chn, "ping", %{
        "message" => "pong",
        "time" => System.system_time(:second)
      })

    Logger.debug("Ping/Pong Reply: #{inspect(reply)}")

    {:noreply, state}
  end

  def handle_info(%Message{event: "report", payload: payload}, state) do
    Logger.debug("report #{payload}: #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info(
        %Message{event: "command", payload: %{"command" => command} = payload},
        %{:office => chn} = state
      ) do
    Logger.debug("run command #{command}")
    {out, code} = System.cmd("bash", ["-c", command])

    r =
      PhoenixClient.Channel.push_async(
        chn,
        "command:result",
        Map.merge(payload, %{
          "output" => out,
          "code" => code
        })
      )

    Logger.debug("run command #{command} #{code}\n#{out}\n#{r}")

    {:noreply, state}
  end

  def handle_info(%Message{event: event, payload: payload}, state) do
    Logger.warning("Unhandled event: #{inspect(event)}, Message: #{inspect(payload)}")
    {:noreply, state}
  end
end
