defmodule GSMLG.Commander.Office do
  use GenServer
  require Logger

  alias PhoenixClient.{Channel, Message}

  def get_channel() do
    GenServer.call(__MODULE__, :get_channel)
  end

  @doc """
  push event to server
  """
  @spec push(String.t(), any) :: {:ok, term} | {:error, term}
  def push(topic, message) do
    chn = get_channel()
    PhoenixClient.Channel.push(chn, topic, message)
  end

  @doc """
  push event to server async
  """
  @spec push_async(String.t(), any) :: :ok | :error
  def push_async(topic, message) do
    chn = get_channel()
    PhoenixClient.Channel.push_async(chn, topic, message)
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init([]) do
    {:ok, %{channel: nil}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    case Channel.join(GSMLG.Commander.Socket, office_name()) do
      {:ok, response, channel} ->
        Logger.info("Office join success: " <> inspect(response))
        state = state |> Map.put(:channel, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        Logger.error("Office join failed: " <> inspect(reason))
        Logger.debug("Office join failed: " <> "rejoin after 15 seconds.")
        Process.sleep(15_000)
        {:noreply, state, {:continue, :join}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:get_channel, _from, state) do
    {:reply, state |> Map.get(:channel), state}
  end

  @impl true
  def handle_info(:ping, %{:channel => chn} = state) do
    Process.send_after(__MODULE__, :ping, 60_000)

    reply =
      PhoenixClient.Channel.push(chn, "ping", %{
        "message" => "ping",
        "time" => System.system_time(:second)
      })

    Logger.debug("Office Ping/Pong (#{System.system_time(:second)}) Reply: #{inspect(reply)}")

    {:noreply, state}
  end

  def handle_info(%Message{event: "report", payload: payload}, state) do
    Logger.debug("report #{payload}: #{inspect(state)}")
    {:noreply, state}
  end

  def handle_info(
        %Message{event: "command", payload: %{"command" => command} = payload},
        %{:channel => chn} = state
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

  defp office_name() do
    name =
      Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
      |> Keyword.get(:name)

    "commander:#{name}"
  end
end
