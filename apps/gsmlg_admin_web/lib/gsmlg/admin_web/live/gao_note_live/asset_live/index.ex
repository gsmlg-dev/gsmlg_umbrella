defmodule GSMLG.AdminWeb.GaoNoteLive.AssetLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(active_menu: "gao_note_assets")
      |> allow_upload(:asset, accept: :any, max_entries: 3)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _url, socket) do
    note = GaoNote.get_note!(id)

    {:noreply,
     assign(socket,
       page_title: "GaoNote Assets",
       active_menu: "gao_note_assets",
       note: note,
       assets: GaoNote.list_assets(note),
       attach_form: to_form(%{"storage_file_id" => "", "role" => "attachment"}, as: :asset)
     )}
  end

  def handle_params(_params, _url, socket) do
    {:noreply,
     assign(socket,
       page_title: "GaoNote Assets",
       active_menu: "gao_note_assets",
       assets: GaoNote.list_all_assets()
     )}
  end

  @impl true
  def handle_event("validate_upload", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("upload", params, socket) do
    attrs = Map.get(params, "asset", %{})
    note = socket.assigns.note
    actor = current_actor(socket)

    results =
      consume_uploaded_entries(socket, :asset, fn %{path: path}, entry ->
        metadata = %{"original_name" => entry.client_name, "visibility" => "private"}
        attrs = Map.put(attrs, "metadata", metadata)

        case GaoNote.upload_asset(note, path, attrs, actor) do
          {:ok, asset} -> {:ok, {:ok, asset}}
          {:error, reason} -> {:ok, {:error, reason}}
        end
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:noreply, reload(socket) |> put_flash(:info, "Assets uploaded")}
    else
      {:noreply, reload(socket) |> put_flash(:error, "One or more uploads failed")}
    end
  end

  def handle_event("attach", %{"asset" => params}, socket) do
    note = socket.assigns.note
    storage_file_id = Map.get(params, "storage_file_id")
    attrs = Map.drop(params, ["storage_file_id"])

    case GaoNote.attach_asset(note, storage_file_id, attrs, current_actor(socket)) do
      {:ok, _asset} ->
        {:noreply, reload(socket) |> put_flash(:info, "Asset attached")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Attach failed: #{inspect(reason)}")}
    end
  end

  def handle_event("update", %{"id" => id, "asset" => params}, socket) do
    asset = GaoNote.get_asset(id)

    case GaoNote.update_asset(asset, params, current_actor(socket)) do
      {:ok, _asset} ->
        {:noreply, reload(socket) |> put_flash(:info, "Asset updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("detach", %{"id" => id}, socket) do
    asset = GaoNote.get_asset(id)

    case GaoNote.detach_asset(asset, current_actor(socket)) do
      {:ok, _asset} ->
        {:noreply, reload(socket) |> put_flash(:info, "Asset detached")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Detach failed: #{inspect(reason)}")}
    end
  end

  defp reload(socket) do
    assign(socket, assets: GaoNote.list_assets(socket.assigns.note))
  end

  defp current_actor(socket), do: socket.assigns[:current_user]

  defp storage_label(nil), do: "missing storage file"

  defp storage_label(file) do
    "#{file.filename} · #{file.content_type} · #{file.size} bytes"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div :if={@live_action == :all} class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center gap-3">
          <.dm_mdi name="paperclip" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">GaoNote Assets</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link navigate={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_table id="gao-note-assets-table" class="table-bordered" data={@assets}>
          <:col :let={asset} label="Note">
            <.link navigate={~p"/gao_notes/notes/#{asset.note_id}"} class="font-medium text-sm">
              {asset.note.title}
            </.link>
          </:col>
          <:col :let={asset} label="Storage File">
            <span class="font-mono text-xs">{storage_label(asset.storage_file)}</span>
          </:col>
          <:col :let={asset} label="Role">
            <.dm_badge variant="secondary" soft>{asset.role}</.dm_badge>
          </:col>
          <:col :let={asset} label="Caption">
            <span class="text-sm">{asset.caption}</span>
          </:col>
          <:col :let={asset} label="Position">
            <span class="font-mono text-xs">{asset.position}</span>
          </:col>
          <:col :let={asset} label="">
            <.link navigate={~p"/gao_notes/notes/#{asset.note_id}/assets"}>
              <.dm_btn size="xs" variant="ghost" title="Manage">
                <.dm_mdi name="open-in-new" class="w-3.5 h-3.5" />
              </.dm_btn>
            </.link>
          </:col>
        </.dm_table>
      </div>

      <div :if={@live_action != :all} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center gap-3">
          <.dm_mdi name="paperclip" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">{@note.title} Assets</h1>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link patch={~p"/gao_notes/notes/#{@note.id}"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> Note
            </.dm_btn>
          </.link>
          <.link navigate={~p"/gao_notes/notes/#{@note.id}/references"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="link-variant" class="w-4 h-4" /> References
            </.dm_btn>
          </.link>
        </div>

        <form
          id="asset-upload-form"
          phx-submit="upload"
          phx-change="validate_upload"
          class="flex flex-col gap-3"
        >
          <.live_file_input upload={@uploads.asset} class="file-input file-input-bordered w-full" />
          <div class="grid gap-3 md:grid-cols-4">
            <.dm_select
              name="asset[role]"
              value="attachment"
              label="Role"
              options={[
                {"attachment", "Attachment"},
                {"cover", "Cover"},
                {"inline", "Inline"},
                {"source", "Source"}
              ]}
            />
            <.dm_input name="asset[caption]" label="Caption" />
            <.dm_input name="asset[alt_text]" label="Alt Text" />
            <.dm_input name="asset[position]" label="Position" value="0" type="number" />
          </div>
          <button type="submit" class="btn btn-primary">Upload</button>
        </form>

        <.dm_form
          id="asset-attach-form"
          for={@attach_form}
          phx-submit="attach"
          class="grid gap-3 md:grid-cols-[1fr_180px_auto]"
        >
          <.dm_input field={@attach_form[:storage_file_id]} label="Storage File ID" />
          <.dm_select
            field={@attach_form[:role]}
            label="Role"
            options={[
              {"attachment", "Attachment"},
              {"cover", "Cover"},
              {"inline", "Inline"},
              {"source", "Source"}
            ]}
          />
          <:actions>
            <button type="submit" class="btn btn-secondary">Attach Existing</button>
          </:actions>
        </.dm_form>

        <div class="flex flex-col gap-3">
          <div :for={asset <- @assets} class="border border-base-300 rounded-lg p-3">
            <div class="mb-2 font-mono text-xs text-base-content/60">
              {storage_label(asset.storage_file)}
            </div>
            <form
              phx-submit="update"
              phx-value-id={asset.id}
              class="grid gap-3 md:grid-cols-[160px_1fr_1fr_100px_auto]"
            >
              <.dm_select
                name="asset[role]"
                value={asset.role}
                label="Role"
                options={[
                  {"attachment", "Attachment"},
                  {"cover", "Cover"},
                  {"inline", "Inline"},
                  {"source", "Source"}
                ]}
              />
              <.dm_input name="asset[caption]" value={asset.caption} label="Caption" />
              <.dm_input name="asset[alt_text]" value={asset.alt_text} label="Alt Text" />
              <.dm_input name="asset[position]" value={asset.position} label="Position" type="number" />
              <div class="flex items-end gap-2">
                <button type="submit" class="btn btn-ghost btn-sm">Save</button>
                <.dm_btn
                  size="sm"
                  variant="ghost"
                  class="text-error"
                  phx-click="detach"
                  phx-value-id={asset.id}
                  data-confirm="Detach this asset?"
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
