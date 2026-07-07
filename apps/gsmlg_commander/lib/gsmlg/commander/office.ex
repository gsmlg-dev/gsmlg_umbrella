defmodule GSMLG.Commander.Office do
  alias Phoenix.SocketClient

  use SocketClient.Channel

  @join_retry_after 1_000

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

    Phoenix.SocketClient.Channel.push(__MODULE__, topic, message)
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

    Phoenix.SocketClient.Channel.push_async(__MODULE__, topic, message)
  end

  ## Callbacks

  @impl true
  def init(args) when is_list(args) do
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
    join_office(state)
  end

  @impl true
  def handle_info(:join, state) do
    join_office(state)
  end

  @impl true
  def handle_info(:ping, %{channel: channel} = state) when is_pid(channel) do
    Process.send_after(self(), :ping, 60_000)

    ping_time = System.system_time(:second)

    reply =
      Phoenix.SocketClient.Channel.push(channel, "ping", %{
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

  def handle_info(:ping, state), do: join_office(state)

  defp join_office(state) do
    channel_name = office_name()

    GSMLG.Telemetry.info("Office attempting to join channel",
      metadata: %{
        module: __MODULE__,
        operation: "join_channel",
        channel_name: channel_name
      }
    )

    case Phoenix.SocketClient.Channel.join(GSMLG.Commander.Socket, channel_name) do
      {:ok, response, channel} ->
        GSMLG.Telemetry.info("Office successfully joined channel",
          metadata: %{
            module: __MODULE__,
            operation: "join_success",
            channel_name: channel_name,
            response: response
          }
        )

        Process.send_after(self(), :ping, 60_000)
        {:noreply, %{state | channel: channel}}

      {:error, {:already_joined, channel}} ->
        Process.send_after(self(), :ping, 60_000)
        {:noreply, %{state | channel: channel}}

      {:error, reason} ->
        schedule_join_retry(reason, channel_name, state)
    end
  end

  defp schedule_join_retry(reason, channel_name, state)
       when reason in [:socket_not_connected, :socket_not_started] do
    GSMLG.Telemetry.debug("Office waiting for socket before joining channel",
      metadata: %{
        module: __MODULE__,
        operation: "join_waiting_for_socket",
        channel_name: channel_name,
        reason: reason,
        retry_delay: @join_retry_after
      }
    )

    Process.send_after(self(), :join, @join_retry_after)
    {:noreply, state}
  end

  defp schedule_join_retry(reason, channel_name, state) do
    GSMLG.Telemetry.error("Office failed to join channel",
      metadata: %{
        module: __MODULE__,
        operation: "join_failed",
        channel_name: channel_name,
        error: reason,
        will_retry: true,
        retry_delay: @join_retry_after
      }
    )

    Process.send_after(self(), :join, @join_retry_after)
    {:noreply, state}
  end

  @impl true
  def handle_message("report", payload, state) do
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

  @impl true
  def handle_message("command", %{"command" => command} = payload, state) do
    GSMLG.Telemetry.info("Office executing command",
      metadata: %{
        module: __MODULE__,
        operation: "execute_command",
        command: command,
        office_name: office_name()
      }
    )

    # Use span to measure command execution time
    {{output, exit_code}, execution_time} =
      GSMLG.Telemetry.span_with_metadata(
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
          {{out, code}, %{duration: duration, exit_code: code}}
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

    result_payload =
      Map.merge(payload, %{
        "output" => output,
        "code" => exit_code
      })

    push_result =
      Phoenix.SocketClient.Channel.push_async(
        __MODULE__,
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

  @impl true
  def handle_message(event, payload, state) do
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
