defmodule GSMLG.AdminWeb.GaoNoteLive.ReferenceLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, active_menu: "gao_note_references")}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    note = GaoNote.get_note!(id)

    {:noreply,
     assign(socket,
       page_title: "GaoNote References",
       active_menu: "gao_note_references",
       note: note,
       references: GaoNote.list_references(note),
       form: to_form(%{"url" => "", "title" => "", "position" => "0"}, as: :reference)
     )}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     assign(socket,
       page_title: "GaoNote References",
       active_menu: "gao_note_references",
       references: GaoNote.list_all_references()
     )}
  end

  @impl true
  def handle_event("add", %{"reference" => params}, socket) do
    case GaoNote.add_reference(socket.assigns.note, params, current_actor(socket)) do
      {:ok, _reference} ->
        {:noreply, reload(socket) |> put_flash(:info, "Reference added")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Reference failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    reference = GaoNote.get_reference(id)

    case GaoNote.remove_reference(reference, current_actor(socket)) do
      {:ok, _reference} ->
        {:noreply, reload(socket) |> put_flash(:info, "Reference removed")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Remove failed: #{inspect(reason)}")}
    end
  end

  def handle_event("update", %{"id" => id, "reference" => params}, socket) do
    reference = GaoNote.get_reference(id)

    case GaoNote.update_reference(reference, params, current_actor(socket)) do
      {:ok, _reference} ->
        {:noreply, reload(socket) |> put_flash(:info, "Reference updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  defp reload(socket) do
    assign(socket, references: GaoNote.list_references(socket.assigns.note))
  end

  defp current_actor(socket), do: socket.assigns[:current_user]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div :if={@live_action == :all} class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center gap-3">
          <.dm_mdi name="link-variant" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">GaoNote References</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_table id="gao-note-references-table" class="table-bordered" data={@references}>
          <:col :let={reference} label="Note">
            <.link navigate={~p"/gao_notes/notes/#{reference.note_id}"} class="font-medium text-sm">
              {reference.note.title}
            </.link>
          </:col>
          <:col :let={reference} label="Title">
            <span class="text-sm">{reference.title}</span>
          </:col>
          <:col :let={reference} label="URL">
            <span class="font-mono text-xs break-all">{reference.url}</span>
          </:col>
          <:col :let={reference} label="Position">
            <span class="font-mono text-xs">{reference.position}</span>
          </:col>
          <:col :let={reference} label="">
            <.link navigate={~p"/gao_notes/notes/#{reference.note_id}/references"}>
              <.dm_btn size="xs" variant="ghost" title="Manage">
                <.dm_mdi name="open-in-new" class="w-3.5 h-3.5" />
              </.dm_btn>
            </.link>
          </:col>
        </.dm_table>
      </div>

      <div :if={@live_action != :all} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center gap-3">
          <.dm_mdi name="link-variant" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">{@note.title} References</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link patch={~p"/gao_notes/notes/#{@note.id}"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> Note
            </.dm_btn>
          </.link>
          <.link navigate={~p"/gao_notes/notes/#{@note.id}/assets"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="paperclip" class="w-4 h-4" /> Assets
            </.dm_btn>
          </.link>
        </div>

        <.dm_form
          id="reference-add-form"
          for={@form}
          phx-submit="add"
          class="grid gap-3 md:grid-cols-[1fr_1fr_120px_auto]"
        >
          <.dm_input field={@form[:url]} label="URL" />
          <.dm_input field={@form[:title]} label="Title" />
          <.dm_input field={@form[:position]} label="Position" type="number" />
          <:actions>
            <button type="submit" class="btn btn-primary">Add</button>
          </:actions>
        </.dm_form>

        <div class="flex flex-col gap-3">
          <div :for={reference <- @references} class="border border-base-300 rounded-lg p-3">
            <form
              phx-submit="update"
              phx-value-id={reference.id}
              class="grid gap-3 md:grid-cols-[1fr_1fr_120px_auto]"
            >
              <.dm_input name="reference[url]" value={reference.url} label="URL" />
              <.dm_input name="reference[title]" value={reference.title} label="Title" />
              <.dm_input
                name="reference[position]"
                value={reference.position}
                label="Position"
                type="number"
              />
              <div class="flex items-end gap-2">
                <button type="submit" class="btn btn-ghost btn-sm">Save</button>
                <.dm_btn
                  size="sm"
                  variant="ghost"
                  class="text-error"
                  phx-click="delete"
                  phx-value-id={reference.id}
                  data-confirm="Remove this reference?"
                  type="button"
                >
                  <.dm_mdi name="trash-can-outline" class="w-4 h-4" />
                </.dm_btn>
              </div>
            </form>
            <div class="mt-2 font-mono text-xs text-base-content/50 break-all">
              {reference.canonical_url}
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
