defmodule GSMLG.AdminWeb.MnesiaLive.Index do
  use GSMLG.AdminWeb, :live_view
  alias GSMLG.Mnesia

  @impl true
  def mount(_params, _session, socket) do
    GSMLG.Telemetry.debug("Mnesia Live view mounted",
      metadata: %{
        live_view: "MnesiaLive.Index",
        user_id: socket.assigns[:current_user]
      }
    )

    {:ok, assign(socket, info: nil, tables_info: nil)}
  end

  @impl true
  def handle_params(params, _url, socket) do
    GSMLG.Telemetry.debug("Mnesia Live view params handled",
      metadata: %{
        live_view: "MnesiaLive.Index",
        params: params,
        live_action: socket.assigns[:live_action]
      }
    )

    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:page_title, "Mnesia Management")
    |> fetch_info()
  end

  @impl true
  def handle_event("delete", _params, socket) do
    GSMLG.Telemetry.info("Delete event in Mnesia Live view",
      metadata: %{
        live_view: "MnesiaLive.Index",
        event: "delete",
        user_id: socket.assigns[:current_user]
      }
    )

    {:noreply, socket}
  end

  def fetch_info(socket) do
    GSMLG.Telemetry.span([:admin, :mnesia, :fetch_info], %{live_view: "MnesiaLive.Index"}, fn ->
      try do
        info =
          case GSMLG.Mnesia.Transaction.execute_sync(fn -> GSMLG.Mnesia.system() end) do
            {{:ok, system_info}, _metadata} ->
              system_info

            {{:error, reason}, _metadata} ->
              GSMLG.Telemetry.error("Failed to fetch Mnesia system info",
                metadata: %{
                  live_view: "MnesiaLive.Index",
                  error: reason,
                  operation: "fetch_system_info"
                }
              )

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

        GSMLG.Telemetry.debug("Mnesia info fetched successfully",
          metadata: %{
            live_view: "MnesiaLive.Index",
            tables_count: length(tables_info),
            memory_info: Keyword.get(info, :memory),
            node_info: Keyword.get(info, :nodes)
          }
        )

        result_socket =
          socket
          |> assign(:info, info)
          |> assign(:tables_info, tables_info)

        {result_socket, %{status: :ok}}
      rescue
        e ->
          GSMLG.Telemetry.exception(e, __STACKTRACE__,
            metadata: %{
              live_view: "MnesiaLive.Index",
              operation: "fetch_mnesia_info"
            }
          )

          {socket, %{status: :error}}
      end
    end)
    |> case do
      {socket, _metadata} -> socket
    end
  end
end
