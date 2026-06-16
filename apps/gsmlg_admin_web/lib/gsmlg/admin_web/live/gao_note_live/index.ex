defmodule GSMLG.AdminWeb.GaoNoteLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Note, Tag}
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       active_menu: "gao_note_list",
       notes: AsyncResult.loading(),
       filters: %{},
       selected_tags: [],
       tag_options: AsyncResult.loading(),
       tag_input: ""
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = filter_params(params)

    socket
    |> assign(:page_title, "GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:filters, filters)
    |> assign_notes_async(filter_opts(filters))
  end

  defp apply_action(socket, :new, _params) do
    changeset = GaoNote.change_note(%Note{})

    socket
    |> assign(:page_title, "New GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, %Note{})
    |> assign(:references, [])
    |> assign(:assets, [])
    |> assign(:form, to_form(changeset, as: :gao_note))
    |> assign_tag_state([])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    note = GaoNote.get_note!(id)
    selected_tags = Enum.map(note.tags, & &1.name)

    socket
    |> assign(:page_title, "Edit GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, note)
    |> assign(:form, to_form(GaoNote.change_note(note), as: :gao_note))
    |> assign_tag_state(selected_tags)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    note = GaoNote.get_note!(id)

    socket
    |> assign(:page_title, note.title)
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, note)
    |> assign(:references, GaoNote.list_references(note))
    |> assign(:assets, GaoNote.list_assets(note))
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply, push_patch(socket, to: ~p"/gao_notes/notes?#{filters}")}
  end

  def handle_event("validate", %{"gao_note" => params}, socket) do
    selected_tags = selected_tags_from_params(params, socket)

    changeset =
      socket.assigns.note
      |> GaoNote.change_note(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :gao_note))
     |> assign_tag_state(selected_tags)}
  end

  def handle_event("save", %{"gao_note" => params}, socket) do
    save_note(socket, socket.assigns.live_action, params)
  end

  def handle_event("set_tags", %{"tags" => tag_names}, socket) do
    {:noreply, assign_tag_state(socket, tag_names)}
  end

  def handle_event("tag_input_changed", params, socket) do
    {:noreply, assign(socket, :tag_input, Map.get(params, "tag_input", ""))}
  end

  def handle_event("add_tag_option", %{"name" => name}, socket) do
    selected_tags = normalize_tag_names(socket.assigns.selected_tags ++ [name])

    {:noreply,
     socket
     |> assign(:tag_input, "")
     |> assign_tag_state(selected_tags)}
  end

  def handle_event("add_tag_option", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    note = GaoNote.get_note!(id)

    case GaoNote.delete_note(note, current_actor(socket)) do
      {:ok, _note} ->
        {:noreply,
         socket
         |> put_flash(:info, "GaoNote deleted")
         |> push_patch(to: ~p"/gao_notes/notes")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  defp save_note(socket, :new, params) do
    params = put_selected_tags(params, socket)

    case GaoNote.create_note(params, current_actor(socket)) do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, "GaoNote created")
         |> push_patch(to: ~p"/gao_notes/notes/#{note.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :gao_note))}
    end
  end

  defp save_note(socket, :edit, params) do
    params = put_selected_tags(params, socket)

    case GaoNote.update_note(socket.assigns.note, params, current_actor(socket)) do
      {:ok, note} ->
        {:noreply,
         socket
         |> put_flash(:info, "GaoNote updated")
         |> push_patch(to: ~p"/gao_notes/notes/#{note.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :gao_note))}
    end
  end

  defp filter_params(params) do
    %{
      "search" => Map.get(params, "search", ""),
      "tag" => Map.get(params, "tag", "")
    }
  end

  defp filter_opts(filters) do
    [
      search: blank_to_nil(filters["search"]),
      tag: blank_to_nil(filters["tag"]),
      limit: 100
    ]
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp assign_notes_async(socket, opts) do
    assign_async(
      socket,
      :notes,
      fn -> {:ok, %{notes: GaoNote.list_notes(opts)}} end,
      reset: true
    )
  end

  defp selected_tags_from_params(params, socket) do
    params
    |> Map.get("tags", socket.assigns.selected_tags)
    |> normalize_tag_names()
  end

  defp put_selected_tags(params, socket) do
    Map.put(params, "tags", selected_tags_from_params(params, socket))
  end

  defp assign_tag_state(socket, tag_names) do
    selected_tags = normalize_tag_names(tag_names)

    socket
    |> assign(:selected_tags, selected_tags)
    |> assign_tag_options_async(selected_tags)
  end

  defp assign_tag_options_async(socket, selected_tags) do
    assign_async(
      socket,
      :tag_options,
      fn -> {:ok, %{tag_options: tag_options(selected_tags)}} end,
      reset: true
    )
  end

  defp tag_options(selected_tags) do
    existing_names =
      [limit: 200]
      |> GaoNote.list_tags()
      |> Enum.map(& &1.name)

    existing_names
    |> Enum.concat(selected_tags)
    |> normalize_tag_names()
    |> Enum.map(&%{value: &1, label: &1})
  end

  defp normalize_tag_names(tag_names) do
    tag_names
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&Tag.normalize_display_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&Tag.slugify/1)
  end

  defp selected_tag_options(selected_tags) do
    selected_tags
    |> normalize_tag_names()
    |> Enum.map(&%{value: &1, label: &1})
  end

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp current_actor(socket), do: socket.assigns[:current_user]

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}) do
    Enum.map(errors, &translate_error/1)
  end

  defp translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(GSMLG.AdminWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GSMLG.AdminWeb.Gettext, "errors", msg, opts)
    end
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div :if={@live_action == :index} class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="notebook-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote</h1>
          </div>
          <.link patch={~p"/gao_notes/notes/new"}>
            <.dm_btn variant="primary" size="sm">
              <.dm_mdi name="plus" class="w-4 h-4" /> New
            </.dm_btn>
          </.link>
        </div>

        <form
          id="gao-note-filter-form"
          phx-change="filter"
          phx-submit="filter"
          class="grid gap-3 md:grid-cols-2"
        >
          <.dm_input name="filters[search]" value={@filters["search"]} label="Search" />
          <.dm_input name="filters[tag]" value={@filters["tag"]} label="Tag" />
        </form>

        <.dm_skeleton_table
          :if={async_loading?(@notes)}
          id="gao-note-table-loading"
          rows={6}
          columns={6}
          animation="wave"
          loading_label="Loading GaoNote notes"
        />
        <div :if={async_failed?(@notes)} class="text-sm text-error">
          Unable to load notes.
        </div>

        <.dm_table
          :if={!async_loading?(@notes)}
          id="gao-note-table"
          class="table-bordered"
          data={async_value(@notes, [])}
        >
          <:col :let={note} label="Title">
            <span class="font-medium text-sm">{note.title}</span>
          </:col>
          <:col :let={note} label="Tags">
            <div class="flex min-w-32 max-w-56 flex-wrap gap-1">
              <.dm_badge :for={tag <- note.tags} variant="primary" soft>{tag.name}</.dm_badge>
              <span :if={note.tags == []} class="text-xs text-base-content/40">None</span>
            </div>
          </:col>
          <:col :let={note} label="Creator">
            <span class="font-mono text-xs">{note.creator}</span>
          </:col>
          <:col :let={note} label="Created">
            <span class="font-mono text-xs">{format_dt(note.created_at)}</span>
          </:col>
          <:col :let={note} label="Updated">
            <span class="font-mono text-xs">{format_dt(note.updated_at)}</span>
          </:col>
          <:col :let={note} label="">
            <div class="flex items-center gap-1">
              <.link patch={~p"/gao_notes/notes/#{note.id}"}>
                <.dm_btn size="xs" variant="ghost" title="View">
                  <.dm_mdi name="eye-outline" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.link patch={~p"/gao_notes/notes/#{note.id}/edit"}>
                <.dm_btn size="xs" variant="ghost" title="Edit">
                  <.dm_mdi name="pencil-outline" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.link navigate={~p"/gao_notes/notes/#{note.id}/references"}>
                <.dm_btn size="xs" variant="ghost" title="References">
                  <.dm_mdi name="link-variant" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.link navigate={~p"/gao_notes/notes/#{note.id}/assets"}>
                <.dm_btn size="xs" variant="ghost" title="Assets">
                  <.dm_mdi name="paperclip" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.dm_modal
                id={"confirm-dialog-gao-note-list-delete-#{note.id}"}
                size="sm"
                hide_close
                dialog_label="Delete GaoNote"
              >
                <:trigger :let={dialog_id}>
                  <.dm_btn
                    id={"gao-note-list-delete-#{note.id}"}
                    size="xs"
                    variant="ghost"
                    class="text-error"
                    title="Delete"
                    onclick={"document.getElementById('#{dialog_id}').show()"}
                  >
                    <.dm_mdi name="trash-can-outline" class="w-3.5 h-3.5" />
                  </.dm_btn>
                </:trigger>
                <:title>Delete GaoNote</:title>
                <:body>
                  <p class="text-sm text-base-content/80">Delete this GaoNote?</p>
                </:body>
                <:footer>
                  <div class="flex justify-end gap-2">
                    <form id={"gao-note-delete-list-cancel-#{note.id}"} method="dialog">
                      <button
                        type="button"
                        class="btn btn-ghost btn-sm"
                        onclick={"document.getElementById('confirm-dialog-gao-note-list-delete-#{note.id}').close()"}
                      >
                        Cancel
                      </button>
                    </form>
                    <form id={"gao-note-delete-list-confirm-#{note.id}"} method="dialog">
                      <.dm_btn
                        type="submit"
                        variant="error"
                        size="sm"
                        phx-click="delete"
                        phx-value-id={note.id}
                      >
                        Delete
                      </.dm_btn>
                    </form>
                  </div>
                </:footer>
              </.dm_modal>
            </div>
          </:col>
        </.dm_table>
      </div>

      <div :if={@live_action in [:new, :edit]} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center gap-3">
          <.dm_mdi name="notebook-edit-outline" class="w-5 h-5 text-primary" />
          <h1 class="font-semibold text-base-content">{@page_title}</h1>
        </div>

        <div class="flex gap-2">
          <.link patch={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> All Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_form
          id="gao-note-form"
          for={@form}
          phx-submit="save"
          phx-change="validate"
          class="grid gap-4"
        >
          <.dm_input field={@form[:title]} label="Title" errors={field_errors(@form[:title])} />
          <.dm_input
            field={@form[:creator]}
            label="Creator"
            errors={field_errors(@form[:creator])}
          />
          <.dm_input
            field={@form[:description]}
            label="Description"
            errors={field_errors(@form[:description])}
          />

          <div class="grid gap-2">
            <.dm_label for="gao-note-tags">Tags</.dm_label>
            <.dm_multi_select
              id="gao-note-tags"
              name="gao_note[tags]"
              options={async_value(@tag_options, selected_tag_options(@selected_tags))}
              selected={@selected_tags}
              placeholder="Select tags"
              searchable
              show_counter
              clearable
              tag_variant="primary"
              phx-hook="GaoNoteTagsMultiSelect"
            />
            <div
              :if={async_loading?(@tag_options)}
              id="gao-note-tags-loading"
              class="text-sm text-base-content/60"
            >
              Loading tags
            </div>
            <div :if={async_failed?(@tag_options)} class="text-sm text-error">
              Unable to load tags.
            </div>
            <div class="grid gap-2 md:grid-cols-[1fr_auto] md:items-end">
              <.dm_input
                id="gao-note-tag-input"
                name="tag_input"
                value={@tag_input}
                label="Add tag option"
                autocomplete="off"
                phx-change="tag_input_changed"
              />
              <.dm_btn
                type="button"
                variant="secondary"
                phx-click="add_tag_option"
                phx-value-name={@tag_input}
              >
                <.dm_mdi name="plus" class="w-4 h-4" /> Add
              </.dm_btn>
            </div>
          </div>

          <% content_errors = field_errors(@form[:content]) %>
          <div class="grid gap-2" phx-feedback-for={@form[:content].name}>
            <.dm_label for={@form[:content].id}>Markdown Content</.dm_label>
            <.dm_markdown_input
              field={@form[:content]}
              placeholder="Write markdown content"
              theme="auto"
              resize="vertical"
              live_preview
              debounce={250}
              class="min-h-[28rem]"
              aria-invalid={content_errors != [] && "true"}
              aria-describedby={content_errors != [] && "#{@form[:content].id}-errors"}
            />
            <div :if={content_errors != []} id={"#{@form[:content].id}-errors"}>
              <.dm_error :for={msg <- content_errors}>{msg}</.dm_error>
            </div>
          </div>

          <:actions>
            <button type="submit" class="btn btn-primary">Save</button>
            <.link patch={~p"/gao_notes/notes"}>
              <.dm_btn variant="ghost" type="button">Cancel</.dm_btn>
            </.link>
          </:actions>
        </.dm_form>
      </div>

      <div :if={@live_action == :show} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="notebook-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">{@note.title}</h1>
          </div>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link patch={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> All Notes
            </.dm_btn>
          </.link>
          <.link patch={~p"/gao_notes/notes/#{@note.id}/edit"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="pencil-outline" class="w-4 h-4" /> Edit
            </.dm_btn>
          </.link>
          <.link navigate={~p"/gao_notes/notes/#{@note.id}/references"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="link-variant" class="w-4 h-4" /> References
            </.dm_btn>
          </.link>
          <.link navigate={~p"/gao_notes/notes/#{@note.id}/assets"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="paperclip" class="w-4 h-4" /> Assets
            </.dm_btn>
          </.link>
          <.dm_modal
            id={"confirm-dialog-gao-note-delete-#{@note.id}"}
            size="sm"
            hide_close
            dialog_label="Delete GaoNote"
          >
            <:trigger :let={dialog_id}>
              <.dm_btn
                id={"gao-note-delete-#{@note.id}"}
                size="sm"
                variant="ghost"
                class="text-error"
                onclick={"document.getElementById('#{dialog_id}').show()"}
              >
                <.dm_mdi name="trash-can-outline" class="w-4 h-4" /> Delete
              </.dm_btn>
            </:trigger>
            <:title>Delete GaoNote</:title>
            <:body>
              <p class="text-sm text-base-content/80">Delete this GaoNote?</p>
            </:body>
            <:footer>
              <div class="flex justify-end gap-2">
                <form id={"gao-note-delete-cancel-#{@note.id}"} method="dialog">
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    onclick={"document.getElementById('confirm-dialog-gao-note-delete-#{@note.id}').close()"}
                  >
                    Cancel
                  </button>
                </form>
                <form id={"gao-note-delete-confirm-#{@note.id}"} method="dialog">
                  <.dm_btn
                    type="submit"
                    variant="error"
                    size="sm"
                    phx-click="delete"
                    phx-value-id={@note.id}
                  >
                    Delete
                  </.dm_btn>
                </form>
              </div>
            </:footer>
          </.dm_modal>
        </div>

        <div class="grid gap-3 md:grid-cols-2">
          <div>
            <div class="font-mono text-xs text-base-content/50">Creator</div>
            <div class="font-mono text-xs">{@note.creator}</div>
          </div>
          <div>
            <div class="font-mono text-xs text-base-content/50">Created</div>
            <div class="font-mono text-xs">{format_dt(@note.created_at)}</div>
          </div>
          <div>
            <div class="font-mono text-xs text-base-content/50">Updated</div>
            <div class="font-mono text-xs">{format_dt(@note.updated_at)}</div>
          </div>
        </div>

        <div class="text-sm text-base-content/70">
          {@note.description}
        </div>

        <div :if={@note.tags != []} class="flex flex-wrap gap-2">
          <.dm_badge :for={tag <- @note.tags} variant="primary" soft>{tag.name}</.dm_badge>
        </div>

        <div class="w-full">
          <.dm_markdown
            id={"gao-note-content-#{@note.id}"}
            content={@note.content || ""}
            theme="auto"
            class="block w-full"
          />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
