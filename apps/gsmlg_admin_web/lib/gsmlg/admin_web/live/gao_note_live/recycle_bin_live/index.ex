defmodule GSMLG.AdminWeb.GaoNoteLive.RecycleBinLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.GaoNoteLive.{BatchActionComponents, BatchSelection}
  alias GSMLG.GaoNote
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_menu, "gao_note_recycle_bin")
     |> assign(:notes, AsyncResult.loading())
     |> assign(:batch_selected, MapSet.new())
     |> assign(:purge_form, purge_form())
     |> assign(:purge_error, nil)}
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
    {:noreply,
     socket
     |> reset_batch_purge_state()
     |> assign_deleted_notes_async()}
  end

  def handle_event("toggle_recycle_note", %{"id" => id}, socket) do
    loaded_ids = loaded_note_ids(socket)

    selected =
      if id in loaded_ids do
        BatchSelection.toggle(socket.assigns.batch_selected, id)
      else
        socket.assigns.batch_selected
      end

    {:noreply, assign(socket, :batch_selected, selected)}
  end

  def handle_event("toggle_recycle_note", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_all_recycle_notes", _params, socket) do
    {:noreply,
     assign(
       socket,
       :batch_selected,
       BatchSelection.toggle_all(socket.assigns.batch_selected, loaded_note_ids(socket))
     )}
  end

  def handle_event("clear_recycle_selection", _params, socket) do
    {:noreply, reset_batch_purge_state(socket)}
  end

  def handle_event("open_batch_purge_modal", _params, socket) do
    {:noreply, reset_purge_state(socket)}
  end

  def handle_event("cancel_batch_purge_modal", _params, socket) do
    {:noreply,
     socket
     |> reset_purge_state()
     |> push_event("close-dialog", %{id: "gao-note-recycle-purge-modal"})}
  end

  def handle_event(
        "change_batch_purge_confirmation",
        %{"batch_purge" => %{"confirmation" => confirmation}},
        socket
      )
      when is_binary(confirmation) do
    {:noreply,
     assign(socket,
       purge_form: purge_form(confirmation),
       purge_error: nil
     )}
  end

  def handle_event("change_batch_purge_confirmation", _params, socket) do
    {:noreply, assign_malformed_purge(socket)}
  end

  def handle_event("batch_purge_notes", params, socket) do
    socket = reconcile_batch_selection(socket)

    case batch_purge_confirmation(params) do
      {:ok, "DELETE"} -> submit_batch_purge(socket)
      {:ok, _confirmation} -> {:noreply, assign_invalid_confirmation(socket)}
      :error -> {:noreply, assign_malformed_purge(socket)}
    end
  end

  def handle_event("restore", %{"id" => id}, socket) do
    case GaoNote.get_deleted_note(id) do
      nil ->
        {:noreply,
         assign_deleted_notes_async(socket) |> put_flash(:error, "Deleted note not found")}

      note ->
        case GaoNote.restore_note(note, current_actor(socket)) do
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
        case GaoNote.permanently_delete_note(note, current_actor(socket)) do
          {:ok, _note} ->
            {:noreply,
             assign_deleted_notes_async(socket) |> put_flash(:info, "Note permanently deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Permanent delete failed: #{inspect(reason)}")}
        end
    end
  end

  @impl true
  def handle_async(:load_deleted_notes, {:ok, notes}, socket) do
    loaded_ids = Enum.map(notes, & &1.id)

    {:noreply,
     assign(socket,
       notes: AsyncResult.ok(socket.assigns.notes, notes),
       batch_selected: BatchSelection.reconcile(socket.assigns.batch_selected, loaded_ids)
     )}
  end

  def handle_async(:load_deleted_notes, {:exit, _reason}, socket) do
    {:noreply, assign(socket, :notes, AsyncResult.failed(socket.assigns.notes, :load_failed))}
  end

  @impl true
  def render(assigns) do
    loaded_notes = async_value(assigns.notes, [])
    loaded_ids = Enum.map(loaded_notes, & &1.id)

    assigns =
      assign(assigns,
        loaded_notes: loaded_notes,
        batch_selection_state: BatchSelection.state(assigns.batch_selected, loaded_ids)
      )

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

          <.dm_btn id="gao-note-recycle-refresh" variant="ghost" phx-click="refresh">
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
          <BatchActionComponents.recycle_toolbar
            :if={MapSet.size(@batch_selected) > 0}
            selected_count={MapSet.size(@batch_selected)}
            clear_event="clear_recycle_selection"
            purge_modal_id="gao-note-recycle-purge-modal"
          />

          <BatchActionComponents.purge_modal
            :if={MapSet.size(@batch_selected) > 0 or @purge_error}
            form={@purge_form}
            selected_count={MapSet.size(@batch_selected)}
            error={@purge_error}
          />

          <table id="gao-note-recycle-table" class="w-full text-left text-sm">
            <thead class="border-b border-base-300 bg-base-200/70 text-xs uppercase tracking-wide text-base-content/60">
              <tr>
                <th scope="col" class="w-12 px-4 py-3">
                  <BatchActionComponents.selection_checkbox
                    id="gao-note-recycle-select-all"
                    checked={@batch_selection_state != :none}
                    state={@batch_selection_state}
                    event="toggle_all_recycle_notes"
                    label="Select all loaded deleted notes"
                  />
                </th>
                <th scope="col" class="px-4 py-3">Note</th>
                <th scope="col" class="px-4 py-3">Labels</th>
                <th scope="col" class="px-4 py-3">Deleted</th>
                <th scope="col" class="px-4 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-300">
              <tr :if={@loaded_notes == []}>
                <td colspan="5" class="px-4 py-10 text-center text-base-content/50">
                  Recycle bin is empty.
                </td>
              </tr>

              <tr
                :for={note <- @loaded_notes}
                id={"deleted-note-#{note.id}"}
                data-state={if MapSet.member?(@batch_selected, note.id), do: "selected", else: "none"}
              >
                <td class="px-4 py-4 align-top">
                  <BatchActionComponents.selection_checkbox
                    id={"gao-note-recycle-select-#{note.id}"}
                    checked={MapSet.member?(@batch_selected, note.id)}
                    state={if MapSet.member?(@batch_selected, note.id), do: :all, else: :none}
                    event="toggle_recycle_note"
                    value_id={note.id}
                    label={"Select #{note.title}"}
                  />
                </td>
                <td class="px-4 py-4 align-top">
                  <div class="font-medium text-base-content">{note.title}</div>
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
    socket
    |> cancel_async(:load_deleted_notes)
    |> assign(:notes, AsyncResult.loading())
    |> start_async(:load_deleted_notes, fn -> GaoNote.list_deleted_notes(limit: 200) end)
  end

  defp purge_form(confirmation \\ "") do
    to_form(%{"confirmation" => confirmation}, as: :batch_purge)
  end

  defp reset_batch_purge_state(socket) do
    socket
    |> assign(:batch_selected, MapSet.new())
    |> reset_purge_state()
  end

  defp reset_purge_state(socket) do
    assign(socket,
      purge_form: purge_form(),
      purge_error: nil
    )
  end

  defp reconcile_batch_selection(socket) do
    assign(
      socket,
      :batch_selected,
      BatchSelection.reconcile(socket.assigns.batch_selected, loaded_note_ids(socket))
    )
  end

  defp loaded_note_ids(%{assigns: %{notes: %AsyncResult{ok?: true, result: notes}}}),
    do: Enum.map(notes, & &1.id)

  defp loaded_note_ids(_socket), do: []

  defp batch_purge_confirmation(%{
         "batch_purge" => %{"confirmation" => confirmation}
       })
       when is_binary(confirmation),
       do: {:ok, confirmation}

  defp batch_purge_confirmation(_params), do: :error

  defp submit_batch_purge(socket) do
    if MapSet.size(socket.assigns.batch_selected) > 0 do
      note_ids = socket.assigns.batch_selected |> MapSet.to_list() |> Enum.sort()

      case GaoNote.batch_permanently_delete_notes(note_ids, current_actor(socket)) do
        {:ok, %{purged: purged}} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{purged} notes permanently deleted")
           |> push_event("close-dialog", %{
             id: "gao-note-recycle-purge-modal",
             focus: "#gao-note-recycle-refresh"
           })
           |> reset_batch_purge_state()
           |> assign_deleted_notes_async()}

        {:error, reason} ->
          {:noreply, assign(socket, :purge_error, batch_purge_error(reason))}
      end
    else
      {:noreply,
       assign(socket, :purge_error, "Select at least one loaded deleted note and try again.")}
    end
  end

  defp assign_invalid_confirmation(socket) do
    assign(
      socket,
      :purge_error,
      "Type DELETE exactly to permanently delete the selected notes."
    )
  end

  defp assign_malformed_purge(socket) do
    assign(socket,
      purge_form: purge_form(),
      purge_error: "Purge confirmation is invalid. Type DELETE exactly and try again."
    )
  end

  defp batch_purge_error({:notes_unavailable, _details}),
    do: "Some selected notes changed or disappeared. Nothing was permanently deleted."

  defp batch_purge_error({:invalid_selection, _details}),
    do: "The selected deleted notes are invalid. Clear the selection and try again."

  defp batch_purge_error({:batch_purge_failed, _details}),
    do: "Attachment cleanup could not be scheduled. Nothing was permanently deleted. Try again."

  defp batch_purge_error({:batch_write_failed, _details}),
    do: "The selected notes could not be permanently deleted. Nothing was deleted."

  defp batch_purge_error({:batch_audit_failed, _details}),
    do: "The purge audit could not be saved. Nothing was permanently deleted."

  defp batch_purge_error(_reason),
    do: "The selected notes could not be permanently deleted. Nothing was deleted."

  defp current_actor(socket), do: socket.assigns[:current_user]

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
