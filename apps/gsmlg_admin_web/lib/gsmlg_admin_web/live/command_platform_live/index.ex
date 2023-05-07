defmodule GSMLGAdminWeb.CommandPlatformLive.Index do
  use GSMLGAdminWeb, :live_view

  require Logger

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, commanders: [], command_form: to_form(%{}, as: :command))}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Command Platform")
    |> assign(:test_button, "Test Button")
    |> fetch_commanders()
  end

  @impl true
  def handle_event("check-table", _params, socket) do
    GSMLG.CommandPlatform.Commander.ensure_table()
    {:noreply, socket}
  end

  def handle_event("update_test", _params, socket) do
    Process.send_after(self(), :test_done, 10_000)

    socket =
      socket
      |> assign(:test_button, "Testing...")

    {:noreply, socket}
  end

  def handle_event("fetch-commanders", _params, socket) do
    socket = socket |> fetch_commanders()
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
  def handle_info(:test_done, socket) do
    socket =
      socket
      |> assign(:test_button, "Test Button")

    {:noreply, socket}
  end

  def handle_info(any, socket) do
    Logger.debug("unhanlded event: #{inspect(any)}")
    {:noreply, socket}
  end

  defp fetch_commanders(socket) do
    {:ok, commanders} = GSMLG.CommandPlatform.list_commanders()

    socket
    |> assign(:commanders, commanders)
  end
end
