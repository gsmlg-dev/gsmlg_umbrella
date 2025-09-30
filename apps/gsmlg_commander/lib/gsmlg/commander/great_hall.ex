defmodule GSMLG.Commander.GreatHall do
  require Logger

  alias Phoenix.SocketClient

  use SocketClient.Channel

  @impl true
  def init(args) do
    # initialize your channel state
    # args: {sup_pid, socket_pid, topic, params}
    {:ok, args}
  end


  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  push event to server
  """
  @spec push(String.t(), any) :: {:ok, term} | {:error, term}
  def push(topic, message) do
    chn = get_state() |> Map.get(:channel)
    PhoenixClient.Channel.push(chn, topic, message)
  end

  @doc """
  push event to server async
  """
  @spec push_async(String.t(), any) :: :ok | :error
  def push_async(topic, message) do
    chn = get_state() |> Map.get(:channel)
    PhoenixClient.Channel.push_async(chn, topic, message)
  end

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %{peons: [], jobs: [], channel: nil}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    case Channel.join(GSMLG.Commander.Socket, "command_platform") do
      {:ok, response, channel} ->
        Logger.info("GreatHall join success: " <> inspect(response))
        state = state |> Map.put(:channel, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("GreatHall join failed: " <> inspect(reason))
        Logger.debug("GreatHall join failed: " <> "rejoin after 15 seconds.")
        Process.sleep(15_000)
        {:noreply, state, {:continue, :join}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_info(:ping, %{:channel => chn} = state) do
    Process.send_after(__MODULE__, :ping, 60_000)

    reply =
      PhoenixClient.Channel.push(chn, "ping", %{
        "message" => "ping",
        "time" => System.system_time(:second)
      })

    Logger.debug("GreatHall Ping/Pong (#{System.system_time(:second)}) Reply: #{inspect(reply)}")

    {:noreply, state}
  end

  def handle_info(%Message{event: "report", payload: payload}, state) do
    Logger.debug("GreatHall report #{payload}: #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info(%Message{event: event, payload: payload}, state) do
    Logger.warning("Unhandled event: #{inspect(event)}, Message: #{inspect(payload)}")
    {:noreply, state}
  end
end
