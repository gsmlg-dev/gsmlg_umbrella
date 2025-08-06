defmodule GSMLG.AdminWeb.CommandPlatformChannel do
  @moduledoc """
  Command Platform Channel

  """
  require Logger
  use Phoenix.Channel
  alias Phoenix.Socket.Broadcast
  alias GSMLG.CommandPlatform

  @impl true
  def join("command_platform", _msg, socket) do
    {:ok, socket}
  end

  @impl true
  def terminate(reason, socket) do
    Logger.info("#{inspect(socket)} > leave #{inspect(reason)}")

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
    # {:noreply, socket}
    {:reply, {:ok, %{"message" => "pong", "time" => System.system_time(:second)}}, socket}
  end

  def handle_in(
        "command:result",
        %{"output" => output, "code" => code, "commander" => commander, "command" => command},
        socket
      ) do
    Logger.info("Run command `#{command}` on `#{commander}`, code: #{code} output:\n#{output}")

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
    Logger.warning("Unmatched topic: #{any} with #{inspect(payload)}")
    {:noreply, socket}
  end
end
