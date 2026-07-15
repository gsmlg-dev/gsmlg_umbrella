defmodule GSMLG.AdminWeb.GaoNoteLive.RecycleBinLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_menu, "gao_note_recycle_bin")
     |> assign(:notes, AsyncResult.loading())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote Recycle Bin")
     |> assign(:active_menu, "gao_note_recycle_bin")
     |> assign_deleted_notes_async()}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_deleted_notes_async(socket)}
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case GaoNote.get_deleted_note(id) do
      nil ->
        {:noreply,
         assign_deleted_notes_async(socket) |> put_flash(:error, "Deleted note not found")}

      note ->
        case GaoNote.restore_note(note, nil) do
          {:ok, _note} ->
            {:noreply, assign_deleted_notes_async(socket) |> put_flash(:info, "Note restored")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("purge", %{"id" => id}, socket) do
    case GaoNote.get_deleted_note(id) do
      nil ->
        {:noreply,
         assign_deleted_notes_async(socket) |> put_flash(:error, "Deleted note not found")}

      note ->
        case GaoNote.permanently_delete_note(note, nil) do
          {:ok, _note} ->
            {:noreply,
             assign_deleted_notes_async(socket) |> put_flash(:info, "Note permanently deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Permanent delete failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="space-y-6 p-6 w-full">
        <div class="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
          <div>
            <p class="text-sm uppercase tracking-[0.22em] text-base-content/50">GaoNote</p>
            <h1 class="text-3xl font-semibold tracking-tight">Recycle Bin</h1>
            <p class="mt-2 max-w-2xl text-sm text-base-content/65">
              Deleted notes are hidden from normal GaoNote lists. Restore them here or delete them permanently.
            </p>
          </div>

          <.dm_btn variant="ghost" phx-click="refresh">
            Refresh
          </.dm_btn>
        </div>

        <div
          :if={async_loading?(@notes)}
          class="rounded-box border border-base-300 bg-base-100 p-6 text-sm text-base-content/60"
        >
          Loading deleted notes...
        </div>

        <div
          :if={async_failed?(@notes)}
          class="rounded-box border border-error/30 bg-error/10 p-6 text-sm text-error"
        >
          Unable to load deleted notes.
        </div>

        <div
          :if={!async_loading?(@notes) and !async_failed?(@notes)}
          class="overflow-hidden rounded-box border border-base-300 bg-base-100"
        >
          <table class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/70 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th class="px-4 py-3">Note</th>
                <th class="px-4 py-3">Labels</th>
                <th class="px-4 py-3">Deleted</th>
                <th class="px-4 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :if={async_value(@notes, []) == []}>
                <td colspan="4" class="px-4 py-10 text-center text-base-content/50">
                  Recycle bin is empty.
                </td>
              </tr>

              <tr :for={note <- async_value(@notes, [])} id={"deleted-note-#{note.id}"}>
                <td class="px-4 py-4 align-top">
                  <div class="font-medium text-base-content">{note.title}</div>
                  <div class="mt-1 line-clamp-2 max-w-xl text-xs text-base-content/60">
                    {note.description}
                  </div>
                </td>
                <td class="px-4 py-4 align-top">
                  <div class="flex max-w-md flex-wrap gap-1.5">
                    <span :if={note_labels(note) == []} class="text-xs text-base-content/40">No labels</span>
                    <span
                      :for={label <- note_labels(note)}
                      class="rounded-full border border-base-300 bg-base-200 px-2 py-0.5 text-xs text-base-content/70"
                    >
                      {label_text(label)}
                    </span>
                  </div>
                </td>
                <td class="px-4 py-4 align-top font-mono text-xs text-base-content/60">
                  {format_dt(note.deleted_at)}
                </td>
                <td class="px-4 py-4 align-top">
                  <div class="flex justify-end gap-2">
                    <.dm_btn size="sm" variant="ghost" phx-click="restore" phx-value-id={note.id}>
                      Restore
                    </.dm_btn>
                    <.dm_btn
                      size="sm"
                      variant="error"
                      phx-click="purge"
                      phx-value-id={note.id}
                      data-confirm="Permanently delete this note? This cannot be undone."
                    >
                      Delete permanently
                    </.dm_btn>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_deleted_notes_async(socket) do
    assign_async(
      socket,
      :notes,
      fn -> {:ok, %{notes: GaoNote.list_deleted_notes(limit: 200)}} end,
      reset: true
    )
  end

  defp note_labels(%{labels: %Ecto.Association.NotLoaded{}}), do: []
  defp note_labels(%{labels: labels}) when is_list(labels), do: labels
  defp note_labels(_note), do: []

  defp label_text(%{label_setting: %{name: key}, value: value}) when value in [nil, ""], do: key
  defp label_text(%{label_setting: %{name: key}, value: value}), do: "#{key}=#{value}"
  defp label_text(_label), do: ""

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false
end
