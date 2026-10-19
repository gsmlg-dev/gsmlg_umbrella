defmodule GSMLG.AdminWeb.StorageLive.FolderTree do
  use GSMLG.AdminWeb, :html

  alias GSMLG.Storage.Inventory

  attr :nodes, :list, required: true
  attr :prefix, :string, required: true
  attr :expanded, :any, required: true
  attr :total_files, :integer, required: true
  attr :backend_id, :string, default: nil
  attr :folder_errors, :map, default: %{}
  attr :busy, :boolean, default: false

  def folder_tree(assigns) do
    ~H"""
    <nav
      id="storage-folder-tree"
      phx-hook="StorageFolderActions"
      class="storage-folder-tree w-full max-h-56 lg:max-h-none min-w-0 shrink-0 border-b lg:border-b-0 border-base-300 overflow-y-auto p-3"
      aria-label="S3 folders"
    >
      <p class="menu-title px-2 pt-1 pb-2">Folders</p>
      <.link
        id="storage-root-folder"
        patch={~p"/storage"}
        aria-current={@prefix == "" && "page"}
        class="menu-item min-w-0 px-2 mb-2"
      >
        <.dm_mdi name="folder-multiple-outline" class="w-4 h-4 shrink-0" />
        <span class="min-w-0 flex-1 truncate">All Files</span>
        <span class="text-xs tabular-nums opacity-60" title="Files in this bucket">
          {@total_files}
        </span>
      </.link>
      <ul class="space-y-0.5" role="list">
        <.folder_node
          :for={node <- @nodes}
          node={node}
          prefix={@prefix}
          expanded={@expanded}
          backend_id={@backend_id}
          folder_errors={@folder_errors}
          busy={@busy}
        />
      </ul>
    </nav>
    """
  end

  attr :node, :map, required: true
  attr :prefix, :string, required: true
  attr :expanded, :any, required: true
  attr :backend_id, :string, required: true
  attr :folder_errors, :map, required: true
  attr :busy, :boolean, required: true

  defp folder_node(assigns) do
    assigns =
      assigns
      |> assign(:id, "storage-folder-" <> Inventory.encode_key(assigns.node.prefix))
      |> assign(:open, MapSet.member?(assigns.expanded, assigns.node.prefix))

    ~H"""
    <li class="min-w-0">
      <div class="flex min-w-0 items-center gap-0.5">
        <button
          :if={@node.children != []}
          id={@id <> "-toggle"}
          type="button"
          class="btn btn-ghost btn-xs w-6 h-8 min-h-0 shrink-0 p-0"
          phx-click="toggle_folder"
          phx-value-prefix={Inventory.encode_key(@node.prefix)}
          aria-label={(if @open, do: "Collapse ", else: "Expand ") <> @node.prefix}
          aria-expanded={to_string(@open)}
          aria-controls={@id <> "-children"}
        >
          <.dm_mdi name={if @open, do: "chevron-down", else: "chevron-right"} class="w-4 h-4" />
        </button>
        <span :if={@node.children == []} class="w-6 shrink-0" aria-hidden="true"></span>
        <.link
          id={@id}
          patch={~p"/storage?#{%{prefix: @node.prefix}}"}
          title={@node.prefix}
          aria-current={@prefix == @node.prefix && "page"}
          class="menu-item min-w-0 flex-1 px-2 py-1.5"
        >
          <.dm_mdi
            name={
              if @open or @prefix == @node.prefix, do: "folder-open-outline", else: "folder-outline"
            }
            class="w-4 h-4 shrink-0 text-primary"
          />
          <span class="min-w-0 flex-1 truncate whitespace-pre">{if @node.name == "",
            do: "/",
            else: @node.name}</span>
          <span class="text-xs tabular-nums opacity-60" title="Files including subfolders">
            {@node.count}
          </span>
        </.link>
        <.folder_actions
          :if={@node.children == [] && !is_nil(@backend_id)}
          id={@id}
          node={@node}
          backend_id={@backend_id}
          folder_errors={@folder_errors}
          busy={@busy}
        />
      </div>
      <ul
        :if={@node.children != []}
        id={@id <> "-children"}
        hidden={!@open}
        class="ml-3 border-l border-base-300 pl-2 space-y-0.5"
        role="list"
      >
        <.folder_node
          :for={child <- if(@open, do: @node.children, else: [])}
          node={child}
          prefix={@prefix}
          expanded={@expanded}
          backend_id={@backend_id}
          folder_errors={@folder_errors}
          busy={@busy}
        />
      </ul>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :node, :map, required: true
  attr :backend_id, :string, required: true
  attr :folder_errors, :map, required: true
  attr :busy, :boolean, required: true

  defp folder_actions(assigns) do
    assigns =
      assigns
      |> assign(:encoded_prefix, Inventory.encode_key(assigns.node.prefix))
      |> assign(:rename_error, Map.get(assigns.folder_errors, {assigns.node.prefix, :rename}))
      |> assign(:delete_error, Map.get(assigns.folder_errors, {assigns.node.prefix, :delete}))

    ~H"""
    <.dm_dropdown id={@id <> "-actions"} class="shrink-0">
      <:trigger class="btn btn-ghost btn-xs w-8 h-8 min-h-0 rounded">
        <span class="sr-only">Actions for {@node.prefix}</span>
        <.dm_mdi name="dots-vertical" class="w-4 h-4" aria-hidden="true" />
      </:trigger>
      <:content>
        <button
          type="button"
          role="menuitem"
          class="popover-menu-item"
          command="show-modal"
          commandfor={@id <> "-rename-dialog"}
          phx-click="clear_folder_error"
          phx-value-prefix={@encoded_prefix}
          phx-value-action="rename"
        >
          <.dm_mdi name="pencil-outline" class="w-4 h-4" aria-hidden="true" /> Edit
        </button>
        <button
          type="button"
          role="menuitem"
          class="popover-menu-item text-error"
          command="show-modal"
          commandfor={@id <> "-delete-dialog"}
          phx-click="clear_folder_error"
          phx-value-prefix={@encoded_prefix}
          phx-value-action="delete"
        >
          <.dm_mdi name="delete-outline" class="w-4 h-4" aria-hidden="true" /> Delete
        </button>
      </:content>
    </.dm_dropdown>
    <.dm_modal
      id={@id <> "-rename-dialog"}
      size="sm"
      hide_close
      data-folder-action-trigger={@id <> "-actions-popover-trigger"}
    >
      <:title>Edit folder</:title>
      <:body>
        <form id={@id <> "-rename-form"} phx-submit="rename_folder" class="space-y-4">
          <p class="break-all whitespace-pre-wrap text-sm text-base-content/70">{@node.prefix}</p>
          <input type="hidden" name="folder[prefix]" value={@encoded_prefix} />
          <input type="hidden" name="folder[backend]" value={@backend_id} />
          <.dm_input
            id={@id <> "-name"}
            name="folder[name]"
            value={@node.name}
            label="Folder name"
            required
            autofocus
          />
          <p :if={@rename_error} role="alert" class="text-error text-sm">{@rename_error}</p>
          <div class="flex justify-end gap-2">
            <.dm_btn type="button" command="close" commandfor={@id <> "-rename-dialog"}>
              Cancel
            </.dm_btn>
            <button
              type="submit"
              class="btn btn-primary"
              phx-disable-with="Saving..."
              disabled={@busy}
            >
              Save
            </button>
          </div>
        </form>
      </:body>
    </.dm_modal>
    <.dm_modal
      id={@id <> "-delete-dialog"}
      size="sm"
      hide_close
      data-folder-action-trigger={@id <> "-actions-popover-trigger"}
    >
      <:title>Delete folder?</:title>
      <:body>
        <form id={@id <> "-delete-form"} phx-submit="delete_folder" class="space-y-4">
          <p class="break-all whitespace-pre-wrap text-sm">{@node.prefix}</p>
          <input type="hidden" name="folder[prefix]" value={@encoded_prefix} />
          <input type="hidden" name="folder[backend]" value={@backend_id} />
          <p>
            Permanently delete this folder and all {@node.count} files, including subfolders?
            This cannot be undone.
          </p>
          <p :if={@delete_error} role="alert" class="text-error text-sm">{@delete_error}</p>
          <div class="flex justify-end gap-2">
            <.dm_btn
              type="button"
              command="close"
              commandfor={@id <> "-delete-dialog"}
              autofocus
            >
              Cancel
            </.dm_btn>
            <button
              type="submit"
              class="btn btn-error"
              phx-disable-with="Deleting..."
              disabled={@busy}
            >
              Delete folder
            </button>
          </div>
        </form>
      </:body>
    </.dm_modal>
    """
  end
end
