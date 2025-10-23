defmodule GSMLG.AdminWeb.CommandPlatformChannel do
  @moduledoc """
  Command Platform Channel

  """
  use Phoenix.Channel
  alias Phoenix.Socket.Broadcast

  @impl true
  def join("command_platform", _msg, socket) do
    GSMLG.Telemetry.debug("Command platform channel joined",
      metadata: %{
        channel: "command_platform",
        socket_id: socket.id,
        user_id: socket.assigns[:user_id]
      }
    )

    {:ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    GSMLG.Telemetry.debug("Command platform channel terminated",
      metadata: %{
        channel: "command_platform",
        socket_id: socket.id,
        user_id: socket.assigns[:user_id],
        reason: reason
      }
    )

    :ok
  end

  @impl true
  def handle_info(%Broadcast{topic: _, event: event, payload: payload}, socket) do
    GSMLG.Telemetry.debug("Broadcast received in command platform channel",
      metadata: %{
        channel: "command_platform",
        event: event,
        socket_id: socket.id
      }
    )

    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", %{"message" => "ping", "time" => time}, socket) do
    GSMLG.Telemetry.debug("Ping received in command platform channel",
      metadata: %{
        channel: "command_platform",
        message_type: "ping",
        client_time: time,
        socket_id: socket.id
      }
    )

    {:reply, {:ok, %{"message" => "pong", "time" => System.system_time(:second)}}, socket}
  end

  def handle_in(
        "command:result",
        %{"output" => output, "code" => code, "commander" => commander, "command" => command},
        socket
      ) do
    GSMLG.Telemetry.info("Command execution result received",
      metadata: %{
        channel: "command_platform",
        commander: commander,
        command: command,
        exit_code: code,
        output_length: String.length(output),
        socket_id: socket.id,
        user_id: socket.assigns[:user_id]
      }
    )

    GSMLG.CommandPlatform.add_run_result(%{
      :output => output,
      :code => code,
      :commander => commander,
      :command => command
    })

    case Process.whereis(:CommandResultsView) do
      nil ->
        nil

      pid ->
        Process.send_after(pid, :update_command_results, 500)
    end

    {:noreply, socket}
  end

  def handle_in(any, payload, socket) do
    GSMLG.Telemetry.warn("Unmatched message in command platform channel",
      metadata: %{
        channel: "command_platform",
        message_type: any,
        payload: payload,
        socket_id: socket.id,
        user_id: socket.assigns[:user_id]
      }
    )

    {:noreply, socket}
  end
end
