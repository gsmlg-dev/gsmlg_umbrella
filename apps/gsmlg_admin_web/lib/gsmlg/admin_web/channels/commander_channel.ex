defmodule GSMLG.AdminWeb.CommanderChannel do
  @moduledoc """
  Commander Channel

  """
  use Phoenix.Channel
  alias Phoenix.Socket.Broadcast

  @impl true
  def join("commander:" <> _name, _msg, socket) do
    GSMLG.Telemetry.debug("Commander channel joined",
      metadata: %{
        channel: "commander",
        socket_id: socket.id,
        user_id: socket.assigns[:user_id]
      }
    )

    {:ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    GSMLG.Telemetry.debug("Commander channel terminated",
      metadata: %{
        channel: "commander",
        socket_id: socket.id,
        user_id: socket.assigns[:user_id],
        reason: reason
      }
    )

    :ok
  end

  @impl true
  def handle_info(%Broadcast{topic: _, event: event, payload: payload}, socket) do
    GSMLG.Telemetry.debug("Broadcast received in commander channel",
      metadata: %{
        channel: "commander",
        event: event,
        socket_id: socket.id
      }
    )

    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", %{"message" => "ping", "time" => time}, socket) do
    GSMLG.Telemetry.debug("Ping received in commander channel",
      metadata: %{
        channel: "commander",
        message_type: "ping",
        client_time: time,
        socket_id: socket.id
      }
    )

    {:reply, {:ok, %{"message" => "pong", "time" => System.system_time(:second)}}, socket}
  end

  def handle_in(any, payload, socket) do
    GSMLG.Telemetry.warn("Unmatched message in commander channel",
      metadata: %{
        channel: "commander",
        message_type: any,
        payload: payload,
        socket_id: socket.id
      }
    )

    {:noreply, socket}
  end
end
