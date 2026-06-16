defmodule GSMLG.AdminWeb.GaoNoteLive.LogLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_menu, "gao_note_logs")
     |> assign(:logs, AsyncResult.loading())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote Log")
     |> assign(:active_menu, "gao_note_logs")
     |> assign_logs_async()}
  end

  defp assign_logs_async(socket) do
    assign_async(
      socket,
      :logs,
      fn -> {:ok, %{logs: GaoNote.list_logs(limit: 200)}} end,
      reset: true
    )
  end

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")

  defp details_json(details) do
    Jason.encode!(details || %{}, pretty: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="clipboard-text-clock-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote Log</h1>
          </div>
          <div class="flex gap-2">
            <.link navigate={~p"/gao_notes/notes"}>
              <.dm_btn size="sm" variant="ghost">
                <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
              </.dm_btn>
            </.link>
            <.link navigate={~p"/gao_notes/mcp"}>
              <.dm_btn size="sm" variant="ghost">
                <.dm_mdi name="server-network-outline" class="w-4 h-4" /> MCP
              </.dm_btn>
            </.link>
          </div>
        </div>

        <.dm_skeleton_table
          :if={async_loading?(@logs)}
          id="gao-note-log-loading"
          rows={8}
          columns={7}
          animation="wave"
          loading_label="Loading GaoNote log"
        />
        <div :if={async_failed?(@logs)} class="text-sm text-error">
          Unable to load GaoNote log.
        </div>

        <.dm_table
          :if={!async_loading?(@logs)}
          id="gao-note-log-table"
          class="table-bordered"
          data={async_value(@logs, [])}
        >
          <:col :let={log} label="Time">
            <span class="font-mono text-xs">{format_dt(log.created_at)}</span>
          </:col>
          <:col :let={log} label="Action">
            <.dm_badge size="sm" variant="ghost">{log.action}</.dm_badge>
          </:col>
          <:col :let={log} label="Entity">
            <span class="font-mono text-xs">{log.entity_type}</span>
          </:col>
          <:col :let={log} label="Note">
            <span class="font-mono text-xs break-all">{log.note_id || "-"}</span>
          </:col>
          <:col :let={log} label="Actor">
            <span class="font-mono text-xs">{log.actor_id || "-"}</span>
          </:col>
          <:col :let={log} label="Source">
            <span class="font-mono text-xs">{log.source}</span>
          </:col>
          <:col :let={log} label="Details">
            <pre class="max-w-md overflow-auto rounded bg-base-200 p-2 text-xs">{details_json(log.details)}</pre>
          </:col>
        </.dm_table>
      </div>
    </Layouts.app>
    """
  end
end
