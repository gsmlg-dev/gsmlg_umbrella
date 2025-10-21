defmodule GSMLG.Commander.Office do
  use GenServer

  alias PhoenixClient.{Channel, Message}
  alias Phoenix.SocketClient

  def get_channel() do
    GenServer.call(__MODULE__, :get_channel)
  end

  @doc """
  push event to server
  """
  @spec push(String.t(), any) :: {:ok, term} | {:error, term}
  def push(topic, message) do
    GSMLG.Telemetry.debug("Office pushing message to server",
      metadata: %{
        module: __MODULE__,
        operation: "push",
        topic: topic,
        office_name: office_name()
      }
    )

    chn = get_channel()
    PhoenixClient.Channel.push(chn, topic, message)
  end

  @doc """
  push event to server async
  """
  @spec push_async(String.t(), any) :: :ok | :error
  def push_async(topic, message) do
    GSMLG.Telemetry.debug("Office async pushing message to server",
      metadata: %{
        module: __MODULE__,
        operation: "push_async",
        topic: topic,
        office_name: office_name()
      }
    )

    chn = get_channel()
    PhoenixClient.Channel.push_async(chn, topic, message)
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  ## Callbacks

  @impl true
  def init([]) do
    GSMLG.Telemetry.info("Office initializing",
      metadata: %{
        module: __MODULE__,
        operation: "init",
        office_name: office_name(),
        node: node()
      }
    )
    {:ok, %{channel: nil}, {:continue, :join}}
  end

  @impl true
  def handle_continue(:join, state) do
    channel_name = office_name()
    GSMLG.Telemetry.info("Office attempting to join channel",
      metadata: %{
        module: __MODULE__,
        operation: "join_channel",
        channel_name: channel_name
      }
    )

    case Channel.join(GSMLG.Commander.Socket, channel_name) do
      {:ok, response, channel} ->
        GSMLG.Telemetry.info("Office successfully joined channel",
          metadata: %{
            module: __MODULE__,
            operation: "join_success",
            channel_name: channel_name,
            response: response
          }
        )
        state = state |> Map.put(:channel, channel)
        Process.send_after(__MODULE__, :ping, 60_000)
        {:noreply, state}

      {:error, reason} ->
        GSMLG.Telemetry.error("Office failed to join channel",
          metadata: %{
            module: __MODULE__,
            operation: "join_failed",
            channel_name: channel_name,
            error: reason,
            will_retry: true
          }
        )
        GSMLG.Telemetry.debug("Office will rejoin after 15 seconds",
          metadata: %{
            module: __MODULE__,
            operation: "retry_join",
            channel_name: channel_name,
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
  def handle_call(:get_channel, _from, state) do
    {:reply, state |> Map.get(:channel), state}
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

    GSMLG.Telemetry.debug("Office ping sent",
      metadata: %{
        module: __MODULE__,
        operation: "ping",
        ping_time: ping_time,
        reply: reply,
        office_name: office_name()
      }
    )

    {:noreply, state}
  end

  def handle_info(%Message{event: "report", payload: payload}, state) do
    GSMLG.Telemetry.debug("Office received report",
      metadata: %{
        module: __MODULE__,
        event: "report",
        payload: payload,
        office_name: office_name(),
        state_keys: Map.keys(state)
      }
    )
    {:noreply, state}
  end

  def handle_info(
        %Message{event: "command", payload: %{"command" => command} = payload},
        %{:channel => chn} = state
      ) do
    GSMLG.Telemetry.info("Office executing command",
      metadata: %{
        module: __MODULE__,
        operation: "execute_command",
        command: command,
        office_name: office_name()
      }
    )

    # Use span to measure command execution time
    {output, exit_code, execution_time} = GSMLG.Telemetry.span_with_metadata(
      [:commander, :office, :command_execution],
      %{
        command: command,
        office_name: office_name()
      },
      fn ->
        start_time = System.monotonic_time(:millisecond)
        {out, code} = System.cmd("bash", ["-c", command])
        end_time = System.monotonic_time(:millisecond)
        duration = end_time - start_time
        {out, code, %{duration: duration, exit_code: code}}
      end
    )

    GSMLG.Telemetry.info("Command execution completed",
      metadata: %{
        module: __MODULE__,
        operation: "command_completed",
        command: command,
        exit_code: exit_code,
        execution_time_ms: execution_time.duration,
        output_length: String.length(output),
        office_name: office_name()
      }
    )

    result_payload = Map.merge(payload, %{
      "output" => output,
      "code" => exit_code
    })

    push_result =
      PhoenixClient.Channel.push_async(
        chn,
        "command:result",
        result_payload
      )

    GSMLG.Telemetry.debug("Command result sent to server",
      metadata: %{
        module: __MODULE__,
        operation: "result_sent",
        command: command,
        exit_code: exit_code,
        push_result: push_result,
        office_name: office_name()
      }
    )

    {:noreply, state}
  end

  def handle_info(%Message{event: event, payload: payload}, state) do
    GSMLG.Telemetry.warn("Office received unhandled event",
      metadata: %{
        module: __MODULE__,
        event: event,
        payload: payload,
        office_name: office_name(),
        state_keys: Map.keys(state)
      }
    )
    {:noreply, state}
  end

  defp office_name() do
    name =
      Application.get_env(:gsmlg_commander, GSMLG.Commander, [])
      |> Keyword.get(:name)

    "commander:#{name}"
  end
end
