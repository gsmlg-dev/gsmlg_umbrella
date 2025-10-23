defmodule GSMLG.Commander.GreatHall do
  alias Phoenix.SocketClient

  use SocketClient.Channel

  def get_state() do
    GenServer.call(__MODULE__, :get_state)
  end

  @doc """
  push event to server
  """
  @spec push(String.t(), any) :: {:ok, term} | {:error, term}
  def push(topic, message) do
    GSMLG.Telemetry.debug("Pushing message to server",
      metadata: %{
        module: __MODULE__,
        operation: "push",
        topic: topic,
        message_type: typeof(message)
      }
    )

    chn = get_state() |> Map.get(:channel)
    PhoenixClient.Channel.push(chn, topic, message)
  end

  @doc """
  push event to server async
  """
  @spec push_async(String.t(), any) :: :ok | :error
  def push_async(topic, message) do
    GSMLG.Telemetry.debug("Async pushing message to server",
      metadata: %{
        module: __MODULE__,
        operation: "push_async",
        topic: topic,
        message_type: typeof(message)
      }
    )

    chn = get_state() |> Map.get(:channel)
    PhoenixClient.Channel.push_async(chn, topic, message)
  end

  ## Callbacks

  @impl true
  def init(args) when is_list(args) do
    GSMLG.Telemetry.info("GreatHall initializing",
      metadata: %{
        module: __MODULE__,
        operation: "init",
        node: node()
      }
    )

    {:ok, %{peons: [], jobs: [], channel: nil}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    GSMLG.Telemetry.info("GreatHall attempting to join command platform",
      metadata: %{
        module: __MODULE__,
        operation: "join_platform",
        state_has_channel: Map.has_key?(state, :channel)
      }
    )

    case Phoenix.SocketClient.Channel.join(GSMLG.Commander.Socket, "command_platform") do
      {:ok, response, channel} ->
        GSMLG.Telemetry.info("GreatHall successfully joined command platform",
          metadata: %{
            module: __MODULE__,
            operation: "join_success",
            response: response,
            channel_connected: true
          }
        )

        state = state |> Map.put(:channel, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.error("GreatHall failed to join command platform",
          metadata: %{
            module: __MODULE__,
            operation: "join_failed",
            error: reason,
            will_retry: true
          }
        )

        GSMLG.Telemetry.debug("GreatHall will rejoin after 15 seconds",
          metadata: %{
            module: __MODULE__,
            operation: "retry_join",
            retry_delay: 15_000
          }
        )

        Process.sleep(15_000)
        {:noreply, state, {:continue, :join}}
    end
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_message(event, payload, state) do
    GSMLG.Telemetry.debug("GreatHall received message",
      metadata: %{
        module: __MODULE__,
        event: event,
        payload: payload
      }
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(:ping, %{:channel => chn} = state) do
    Process.send_after(__MODULE__, :ping, 60_000)

    ping_time = System.system_time(:second)

    reply =
      PhoenixClient.Channel.push(chn, "ping", %{
        "message" => "ping",
        "time" => ping_time
      })

    GSMLG.Telemetry.debug("GreatHall ping sent",
      metadata: %{
        module: __MODULE__,
        operation: "ping",
        ping_time: ping_time,
        reply: reply
      }
    )

    {:noreply, state}
  end

  def handle_info(%Message{event: "report", payload: payload}, state) do
    GSMLG.Telemetry.debug("GreatHall received report",
      metadata: %{
        module: __MODULE__,
        event: "report",
        payload: payload,
        state_keys: Map.keys(state)
      }
    )

    {:noreply, state}
  end

  def handle_info(%Message{event: event, payload: payload}, state) do
    GSMLG.Telemetry.warn("GreatHall received unhandled event",
      metadata: %{
        module: __MODULE__,
        event: event,
        payload: payload,
        state_keys: Map.keys(state)
      }
    )

    {:noreply, state}
  end

  defp typeof(term) when is_map(term), do: :map
  defp typeof(term) when is_list(term), do: :list
  defp typeof(term) when is_binary(term), do: :binary
  defp typeof(term) when is_number(term), do: :number
  defp typeof(term) when is_atom(term), do: :atom
  defp typeof(_), do: :unknown
end
