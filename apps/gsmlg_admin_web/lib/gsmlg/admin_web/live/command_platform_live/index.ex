defmodule GSMLG.AdminWeb.CommandPlatformLive.Index do
  use GSMLG.AdminWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(GSMLG.PubSub, "commander_updates")
    end

    {:ok, assign(socket, commanders: [], command_form: to_form(%{}, as: :command))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Command Platform")
    |> fetch_commanders()
  end

  @impl true
  def handle_event("check-table", _params, socket) do
    GSMLG.CommandPlatform.Commander.ensure_table()
    {:noreply, socket}
  end

  def handle_event("validate", params, socket) do
    Logger.info("validate command: #{inspect(params)}")
    {:noreply, socket}
  end

  def handle_event(
        "send_command",
        %{"commander" => commander, "command" => command} = params,
        socket
      ) do
    Logger.info("Send Commander #{commander} command: #{command}")

    case socket.assigns.commanders |> Enum.find(&(&1.name == commander)) do
      %{socket: socket} ->
        Phoenix.Channel.push(socket, "command", params)

      _ ->
        :error
    end

    {:noreply, socket}
  end

  @impl true
  def handle_info(:commander_updates, socket) do
    socket = socket |> fetch_commanders()

    {:noreply, socket}
  end

  @impl true
  def handle_info(any, socket) do
    Logger.debug("unhanlded event: #{inspect(any)}")
    {:noreply, socket}
  end

  defp fetch_commanders(socket) do
    commanders = GSMLG.CommandPlatform.list_commanders()

    socket
    |> assign(:commanders, commanders)
  end
end
