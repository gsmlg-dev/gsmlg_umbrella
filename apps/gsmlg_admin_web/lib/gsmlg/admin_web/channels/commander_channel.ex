defmodule GSMLG.AdminWeb.CommanderChannel do
  @moduledoc """
  Commander Channel

  """
  require Logger
  use Phoenix.Channel
  alias Phoenix.Socket.Broadcast
  alias GSMLG.CommandPlatform

  @impl true
  def join("commander:" <> _name, _msg, socket) do
    {:ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    :ok
  end

  @impl true
  def handle_info(%Broadcast{topic: _, event: event, payload: payload}, socket) do
    push(socket, event, payload)
    {:noreply, socket}
  end

  @impl true
  def handle_in("ping", %{"message" => "ping", "time" => time}, socket) do
    Logger.debug("Get ping at #{time}")
    {:reply, {:ok, %{"message" => "pong", "time" => System.system_time(:second)}}, socket}
  end

  def handle_in(any, payload, socket) do
    Logger.warning("Unmatched topic: #{any} with #{inspect(payload)}")
    {:noreply, socket}
  end
end
