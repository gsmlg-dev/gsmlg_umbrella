defmodule GSMLG.Commander.GreatHall do
  alias Phoenix.SocketClient

  use SocketClient.Channel

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

    Phoenix.SocketClient.Channel.push(__MODULE__, topic, message)
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

    Phoenix.SocketClient.Channel.push_async(__MODULE__, topic, message)
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

    {:ok, %{peons: [], jobs: []}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    GSMLG.Telemetry.info("GreatHall attempting to join command platform",
      metadata: %{
        module: __MODULE__,
        operation: "join_platform"
      }
    )

    case Phoenix.SocketClient.Channel.join(GSMLG.Commander.Socket, "command_platform") do
      {:ok, response, _channel} ->
        GSMLG.Telemetry.info("GreatHall successfully joined command platform",
          metadata: %{
            module: __MODULE__,
            operation: "join_success",
            response: response,
            channel_connected: true
          }
        )

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
  def handle_message("report", payload, state) do
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

  @impl true
  def handle_message(event, payload, state) do
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

  @impl true
  def handle_info(:ping, state) do
    Process.send_after(__MODULE__, :ping, 60_000)

    ping_time = System.system_time(:second)

    reply =
      Phoenix.SocketClient.Channel.push(__MODULE__, "ping", %{
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

  defp typeof(term) when is_map(term), do: :map
  defp typeof(term) when is_list(term), do: :list
  defp typeof(term) when is_binary(term), do: :binary
  defp typeof(term) when is_number(term), do: :number
  defp typeof(term) when is_atom(term), do: :atom
  defp typeof(_), do: :unknown
end
