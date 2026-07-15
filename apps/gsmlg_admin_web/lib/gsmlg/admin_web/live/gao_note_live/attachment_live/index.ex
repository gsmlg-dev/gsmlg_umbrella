defmodule GSMLG.AdminWeb.GaoNoteLive.AttachmentLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(active_menu: "gao_note_attachments")
      |> allow_upload(:attachment, accept: :any, max_entries: 3)

    {:ok, socket}
  end

  @impl true
  def handle_params(_params, _url, %{assigns: %{live_action: :all}} = socket) do
    {:noreply,
     assign(socket,
       page_title: "GaoNote Attachments",
       active_menu: "gao_note_attachments",
       attachments: GaoNote.list_all_attachments()
     )}
  end

  def handle_params(%{"id" => id}, _url, %{assigns: %{live_action: :index}} = socket) do
    note = GaoNote.get_note!(id)

    {:noreply,
     assign(socket,
       page_title: "#{note.title} Attachments",
       active_menu: "gao_note_attachments",
       note: note,
       attachments: GaoNote.list_attachments(note.id),
       attach_form:
         to_form(
           %{
             "storage_file_id" => "",
             "role" => "attachment",
             "path" => "",
             "description" => "",
             "caption" => "",
             "alt_text" => "",
             "position" => "0",
             "visibility" => "private"
           },
           as: :attachment
         )
     )}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", params, socket) do
    params = Map.get(params, "attachment", %{})
    note = socket.assigns.note
    opts = [actor: current_actor(socket)]

    results =
      consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
        upload = %Plug.Upload{
          path: path,
          filename: entry.client_name,
          content_type: entry.client_type
        }

        attrs = upload_attrs(params, entry.client_name)

        case GaoNote.upload_attachment(note.id, upload, attrs, opts) do
          {:ok, attachment} -> {:ok, {:ok, attachment}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    if Enum.all?(results, &match?({:ok, _attachment}, &1)) do
      {:noreply, reload(socket) |> put_flash(:info, "Attachments uploaded")}
    else
      {:noreply, reload(socket) |> put_flash(:error, "One or more uploads failed")}
    end
  end

  def handle_event("attach", %{"attachment" => params}, socket) do
    note = socket.assigns.note
    storage_file_id = Map.get(params, "storage_file_id")
    attrs = attachment_attrs(params)

    case GaoNote.attach_existing_file(
           note.id,
           storage_file_id,
           attrs,
           actor: current_actor(socket)
         ) do
      {:ok, _attachment} ->
        {:noreply, reload(socket) |> put_flash(:info, "Attachment added")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach failed: #{inspect(reason)}")}
    end
  end

  def handle_event("update", %{"id" => id, "attachment" => params}, socket) do
    note = socket.assigns.note

    case GaoNote.get_attachment(id) do
      %{note_id: note_id} = attachment when note_id == note.id ->
        attrs = attachment_attrs(params, attachment.metadata)

        case GaoNote.update_attachment(note.id, attachment.id, attrs) do
          {:ok, _attachment} ->
            {:noreply, reload(socket) |> put_flash(:info, "Attachment updated")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
        end

      _missing_or_other_note ->
        {:noreply, put_flash(socket, :error, "Attachment not found")}
    end
  end

  def handle_event("detach", %{"id" => id}, socket) do
    note = socket.assigns.note

    case GaoNote.detach_attachment(note.id, id) do
      {:ok, _attachment} ->
        {:noreply, reload(socket) |> put_flash(:info, "Attachment detached")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Detach failed: #{inspect(reason)}")}
    end
  end

  defp reload(socket) do
    assign(socket, attachments: GaoNote.list_attachments(socket.assigns.note.id))
  end

  defp upload_attrs(params, client_name) do
    params
    |> attachment_attrs(%{"original_name" => client_name})
    |> put_default_path(client_name)
  end

  defp attachment_attrs(params, metadata \\ %{}) do
    visibility = normalize_visibility(Map.get(params, "visibility"))

    metadata =
      metadata
      |> metadata_map()
      |> Map.put("visibility", visibility)

    params
    |> Map.drop(["storage_file_id", "visibility"])
    |> Map.put("metadata", metadata)
  end

  defp put_default_path(attrs, client_name) do
    case Map.get(attrs, "path") do
      path when is_binary(path) ->
        if String.trim(path) == "" do
          Map.put(attrs, "path", "./#{Path.basename(client_name)}")
        else
          attrs
        end

      _path ->
        Map.put(attrs, "path", "./#{Path.basename(client_name)}")
    end
  end

  defp metadata_map(metadata) when is_map(metadata), do: metadata
  defp metadata_map(_metadata), do: %{}

  defp current_actor(socket), do: socket.assigns[:current_user]

  defp storage_label(nil), do: "missing storage file"

  defp storage_label(file) do
    "#{file.filename} · #{file.content_type} · #{file.size} bytes"
  end

  defp attachment_visibility(attachment) do
    attachment.metadata
    |> metadata_map()
    |> Map.get("visibility", storage_visibility(attachment.storage_file))
    |> normalize_visibility()
  end

  defp storage_visibility(nil), do: "private"

  defp storage_visibility(file) do
    file.metadata
    |> metadata_map()
    |> Map.get("visibility", "private")
  end

  defp normalize_visibility("public"), do: "public"
  defp normalize_visibility(_visibility), do: "private"

  defp role_options do
    [
      {"attachment", "Attachment"},
      {"cover", "Cover"},
      {"inline", "Inline"},
      {"source", "Source"}
    ]
  end

  defp visibility_options do
    [
      {"private", "Private"},
      {"public", "Public"}
    ]
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div :if={@live_action == :all} class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center gap-3">
          <.dm_mdi name="paperclip" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">GaoNote Attachments</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_table id="gao-note-attachments-table" class="table-bordered" data={@attachments}>
          <:col :let={attachment} label="Note">
            <.link
              navigate={~p"/gao_notes/notes/#{attachment.note_id}"}
              class="font-medium text-sm"
            >
              {attachment.note.title}
            </.link>
          </:col>
          <:col :let={attachment} label="Storage File">
            <span class="font-mono text-xs">{storage_label(attachment.storage_file)}</span>
          </:col>
          <:col :let={attachment} label="Role">
            <.dm_badge variant="secondary" soft>{attachment.role}</.dm_badge>
          </:col>
          <:col :let={attachment} label="Path">
            <span class="font-mono text-xs">{attachment.path || "-"}</span>
          </:col>
          <:col :let={attachment} label="Visibility">
            <.dm_badge variant="secondary" soft>{attachment_visibility(attachment)}</.dm_badge>
          </:col>
          <:col :let={attachment} label="Caption">
            <span class="text-sm">{attachment.caption}</span>
          </:col>
          <:col :let={attachment} label="">
            <.link navigate={~p"/gao_notes/notes/#{attachment.note_id}/attachments"}>
              <.dm_btn size="xs" variant="ghost" title="Manage">
                <.dm_mdi name="open-in-new" class="w-3.5 h-3.5" />
              </.dm_btn>
            </.link>
          </:col>
        </.dm_table>
      </div>

      <div :if={@live_action == :index} class="flex flex-col gap-4 p-6 w-full max-w-6xl">
        <div class="flex items-center gap-3">
          <.dm_mdi name="paperclip" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">{@note.title} Attachments</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/gao_notes/notes/#{@note.id}"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> Note
            </.dm_btn>
          </.link>
          <.link navigate={~p"/gao_notes/attachments"}>
            <.dm_btn size="sm" variant="ghost">All Attachments</.dm_btn>
          </.link>
        </div>

        <form
          id="gao-note-attachment-upload-form"
          phx-submit="upload"
          phx-change="validate_upload"
          class="flex flex-col gap-3"
        >
          <.live_file_input
            upload={@uploads.attachment}
            class="file-input file-input-bordered w-full"
          />
          <div class="grid gap-3 md:grid-cols-4">
            <.dm_select
              name="attachment[role]"
              value="attachment"
              label="Role"
              options={role_options()}
            />
            <.dm_input name="attachment[path]" value="" label="Path" placeholder="./data.txt" />
            <.dm_input name="attachment[description]" value="" label="Description" />
            <.dm_input name="attachment[caption]" value="" label="Caption" />
            <.dm_input name="attachment[alt_text]" value="" label="Alt Text" />
            <.dm_input name="attachment[position]" label="Position" value="0" type="number" />
            <.dm_select
              name="attachment[visibility]"
              value="private"
              label="Visibility"
              options={visibility_options()}
            />
          </div>
          <button type="submit" class="btn btn-primary">Upload Attachments</button>
        </form>

        <.dm_form
          id="gao-note-attachment-attach-form"
          for={@attach_form}
          phx-submit="attach"
          class="grid gap-3 md:grid-cols-4"
        >
          <.dm_input field={@attach_form[:storage_file_id]} label="Storage File ID" />
          <.dm_select field={@attach_form[:role]} label="Role" options={role_options()} />
          <.dm_input field={@attach_form[:path]} label="Path" placeholder="./data.txt" />
          <.dm_input field={@attach_form[:description]} label="Description" />
          <.dm_input field={@attach_form[:caption]} label="Caption" />
          <.dm_input field={@attach_form[:alt_text]} label="Alt Text" />
          <.dm_input field={@attach_form[:position]} label="Position" type="number" />
          <.dm_select
            field={@attach_form[:visibility]}
            label="Visibility"
            options={visibility_options()}
          />
          <:actions>
            <button type="submit" class="btn btn-secondary">Attach Existing</button>
          </:actions>
        </.dm_form>

        <div id="gao-note-note-attachments" class="flex flex-col gap-3">
          <div
            :for={attachment <- @attachments}
            id={"gao-note-attachment-#{attachment.id}"}
            class="border border-base-300 rounded-lg p-3"
          >
            <div class="mb-2 flex flex-wrap items-center justify-between gap-2">
              <span class="font-mono text-xs text-base-content/60">
                {storage_label(attachment.storage_file)}
              </span>
              <.dm_badge variant="secondary" soft>{attachment_visibility(attachment)}</.dm_badge>
            </div>
            <form
              id={"gao-note-attachment-update-#{attachment.id}"}
              phx-submit="update"
              phx-value-id={attachment.id}
              class="grid gap-3 md:grid-cols-4"
            >
              <.dm_select
                name="attachment[role]"
                value={attachment.role}
                label="Role"
                options={role_options()}
              />
              <.dm_input
                name="attachment[path]"
                value={attachment.path}
                label="Path"
                placeholder="./data.txt"
              />
              <.dm_input
                name="attachment[description]"
                value={attachment.description}
                label="Description"
              />
              <.dm_input
                name="attachment[caption]"
                value={attachment.caption}
                label="Caption"
              />
              <.dm_input
                name="attachment[alt_text]"
                value={attachment.alt_text}
                label="Alt Text"
              />
              <.dm_input
                name="attachment[position]"
                value={attachment.position}
                label="Position"
                type="number"
              />
              <.dm_select
                name="attachment[visibility]"
                value={attachment_visibility(attachment)}
                label="Visibility"
                options={visibility_options()}
              />
              <div class="flex items-end gap-2">
                <button type="submit" class="btn btn-ghost btn-sm">Save</button>
                <.dm_btn
                  id={"gao-note-attachment-detach-#{attachment.id}"}
                  size="sm"
                  variant="ghost"
                  class="text-error"
                  phx-click="detach"
                  phx-value-id={attachment.id}
                  data-confirm="Detach this attachment?"
                  type="button"
                >
                  <.dm_mdi name="link-off" class="w-4 h-4" />
                </.dm_btn>
              </div>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
