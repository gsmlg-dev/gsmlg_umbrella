defmodule GSMLG.AdminWeb.LobbyChannel do
  @moduledoc """
  Phoenix Channel for the commander dashboard lobby.

  Provides real-time updates about commander status changes,
  new connections, and disconnections for the dashboard view.

  ## Channel Topic

  `commander:lobby` - Lobby for all commander list updates

  ## Features

  - Real-time commander list updates
  - Connection/disconnection notifications
  - Status change broadcasts
  - Aggregate statistics
  """

  # Suppress undefined module warnings for Commander modules (loaded at runtime)
  @compile {:no_warn_undefined, [GSMLG.Commander.SessionManager]}

  use Phoenix.Channel
  require Logger

  alias GSMLG.Commander.SessionManager

  @impl true
  def join("commander:lobby", _params, socket) do
    # Subscribe to commander events
    Phoenix.PubSub.subscribe(GSMLG.PubSub, "commanders:events")

    # Get initial commander list
    commanders = list_commanders()
    stats = calculate_stats(commanders)

    socket =
      socket
      |> assign(:user_id, socket.assigns[:user_id])
      |> assign(:joined_at, DateTime.utc_now())

    GSMLG.Telemetry.debug("User joined commander lobby",
      metadata: %{user_id: socket.assigns[:user_id]}
    )

    {:ok, %{commanders: commanders, stats: stats}, socket}
  end

  @impl true
  def handle_in("get_commanders", params, socket) do
    # Optional filtering
    filters = %{
      status: params["status"],
      tags: params["tags"],
      search: params["search"]
    }

    commanders = list_commanders(filters)
    stats = calculate_stats(commanders)

    {:reply, {:ok, %{commanders: commanders, stats: stats}}, socket}
  end

  @impl true
  def handle_in("get_stats", _params, socket) do
    commanders = list_commanders()
    stats = calculate_stats(commanders)
    {:reply, {:ok, stats}, socket}
  end

  @impl true
  def handle_in("refresh", _params, socket) do
    commanders = list_commanders()
    stats = calculate_stats(commanders)
    {:reply, {:ok, %{commanders: commanders, stats: stats}}, socket}
  end

  @impl true
  def handle_in(event, payload, socket) do
    GSMLG.Telemetry.debug("Unhandled lobby channel event",
      metadata: %{event: event, payload: payload}
    )

    {:noreply, socket}
  end

  # Handle PubSub events

  @impl true
  def handle_info({:commander_event, event}, socket) do
    # Forward commander events to all lobby members
    push(socket, "commander_update", event)

    # Also send updated stats
    commanders = list_commanders()
    stats = calculate_stats(commanders)
    push(socket, "stats_update", stats)

    {:noreply, socket}
  end

  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    GSMLG.Telemetry.debug("User left commander lobby",
      metadata: %{user_id: socket.assigns[:user_id]}
    )

    :ok
  end

  # Private Functions

  defp list_commanders(filters \\ %{}) do
    SessionManager.list_sessions()
    |> maybe_filter_by_status(filters[:status])
    |> maybe_filter_by_tags(filters[:tags])
    |> maybe_filter_by_search(filters[:search])
    |> Enum.map(&format_commander/1)
  end

  defp maybe_filter_by_status(sessions, nil), do: sessions
  defp maybe_filter_by_status(sessions, ""), do: sessions

  defp maybe_filter_by_status(sessions, status) do
    status_atom = String.to_existing_atom(status)
    Enum.filter(sessions, &(&1.state == status_atom))
  rescue
    _ -> sessions
  end

  defp maybe_filter_by_tags(sessions, nil), do: sessions
  defp maybe_filter_by_tags(sessions, []), do: sessions

  defp maybe_filter_by_tags(sessions, tags) when is_list(tags) do
    Enum.filter(sessions, fn session ->
      session_tags = Map.get(session, :tags, [])
      Enum.any?(tags, &(&1 in session_tags))
    end)
  end

  defp maybe_filter_by_tags(sessions, _), do: sessions

  defp maybe_filter_by_search(sessions, nil), do: sessions
  defp maybe_filter_by_search(sessions, ""), do: sessions

  defp maybe_filter_by_search(sessions, search) do
    search_lower = String.downcase(search)

    Enum.filter(sessions, fn session ->
      hostname = session[:hostname] || session[:session_id] || ""
      String.contains?(String.downcase(hostname), search_lower)
    end)
  end

  defp format_commander(session) do
    %{
      id: session[:session_id],
      hostname: session[:hostname] || session[:session_id],
      status: session[:state],
      capabilities: session[:capabilities] || [],
      tags: session[:tags] || [],
      connected_at: session[:created_at],
      last_activity: session[:last_activity],
      metadata: Map.get(session, :metadata, %{})
    }
  end

  defp calculate_stats(commanders) do
    total = length(commanders)

    by_status =
      commanders
      |> Enum.group_by(& &1.status)
      |> Enum.map(fn {status, list} -> {status, length(list)} end)
      |> Map.new()

    by_tag =
      commanders
      |> Enum.flat_map(& &1.tags)
      |> Enum.frequencies()

    %{
      total: total,
      active: Map.get(by_status, :running, 0) + Map.get(by_status, :attached, 0),
      disconnected: Map.get(by_status, :detached, 0),
      pending: Map.get(by_status, :initializing, 0),
      by_status: by_status,
      by_tag: by_tag
    }
  end
end
