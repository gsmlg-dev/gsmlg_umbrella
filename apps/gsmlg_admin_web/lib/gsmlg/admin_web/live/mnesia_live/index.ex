defmodule GSMLG.AdminWeb.MnesiaLive.Index do
  require Logger

  use GSMLG.AdminWeb, :live_view
  alias GSMLG.Mnesia

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, info: nil, tables_info: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Mnesia Management")
    |> fetch_info()
  end

  @impl true
  def handle_event("delete", _params, socket) do
    {:noreply, socket}
  end

  def fetch_info(socket) do
    try do
      info =
        case GSMLG.Mnesia.Transaction.execute_sync(fn -> GSMLG.Mnesia.system() end) do
          {:ok, system_info} ->
            system_info

          {:error, reason} ->
            Logger.error("fetch system_info error: #{inspect(reason)}")
            []
        end

      # get key tables from info
      tables_info =
        info
        |> Keyword.get(:tables, [])
        |> Enum.filter(&(&1 != :schema))
        |> Enum.map(fn t ->
          {t, Mnesia.Table.info(t)}
        end)

      Logger.debug("mnesia info: #{inspect(info)}")
      Logger.debug("mnesia table info: #{inspect(tables_info)}")

      socket
      |> assign(:info, info)
      |> assign(:tables_info, tables_info)
    rescue
      e ->
        Logger.error(Exception.format(:error, e, __STACKTRACE__))
        socket
    end
  end
end
