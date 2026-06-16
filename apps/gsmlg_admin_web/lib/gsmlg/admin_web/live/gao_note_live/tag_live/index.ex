defmodule GSMLG.AdminWeb.GaoNoteLive.TagLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.Tag
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_menu, "gao_note_tags")
     |> assign(:tags, AsyncResult.loading())
     |> assign(:form, tag_form())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote Tags")
     |> assign(:active_menu, "gao_note_tags")
     |> assign_tags_async()}
  end

  @impl true
  def handle_event("create", %{"gao_note_tag" => params}, socket) do
    case GaoNote.create_tag(params) do
      {:ok, _tag} ->
        {:noreply,
         socket
         |> put_flash(:info, "Tag created")
         |> assign(:form, tag_form())
         |> assign_tags_async()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(%{changeset | action: :insert}, as: :gao_note_tag))}
    end
  end

  def handle_event("update", %{"id" => id, "gao_note_tag" => params}, socket) do
    tag = GaoNote.get_tag!(id)

    case GaoNote.update_tag(tag, params) do
      {:ok, _tag} ->
        {:noreply, assign_tags_async(socket) |> put_flash(:info, "Tag updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case GaoNote.get_tag(id) do
      nil ->
        {:noreply, assign_tags_async(socket)}

      %Tag{} = tag ->
        case GaoNote.delete_tag(tag) do
          {:ok, _tag} ->
            {:noreply, assign_tags_async(socket) |> put_flash(:info, "Tag deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  defp assign_tags_async(socket) do
    assign_async(
      socket,
      :tags,
      fn -> {:ok, %{tags: GaoNote.list_tags(limit: 200)}} end,
      reset: true
    )
  end

  defp tag_form do
    %Tag{}
    |> GaoNote.change_tag()
    |> to_form(as: :gao_note_tag)
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp tag_color_style(color) when is_binary(color) do
    color = String.trim(color)

    if Regex.match?(~r/^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$/, color) do
      "background-color: #{color}"
    end
  end

  defp tag_color_style(_color), do: nil

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="tag-multiple-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote Tags</h1>
          </div>
          <.link patch={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_form
          id="gao-note-tag-form"
          for={@form}
          phx-submit="create"
          class="grid gap-3 md:grid-cols-[1fr_180px_auto]"
        >
          <.dm_input field={@form[:name]} label="Name" />
          <.dm_input field={@form[:color]} label="Color" placeholder="#1f6feb" />
          <:actions>
            <button type="submit" class="btn btn-primary gap-2">
              <.dm_mdi name="plus" class="w-4 h-4" /> Add
            </button>
          </:actions>
        </.dm_form>

        <.dm_skeleton_table
          :if={async_loading?(@tags)}
          id="gao-note-tags-loading"
          rows={4}
          columns={5}
          animation="wave"
          loading_label="Loading GaoNote tags"
        />
        <div :if={async_failed?(@tags)} class="text-sm text-error">
          Unable to load tags.
        </div>

        <.dm_table
          :if={!async_loading?(@tags)}
          id="gao-note-tags-table"
          class="table-bordered table-compact"
          data={async_value(@tags, [])}
        >
          <:col :let={tag} label="Name">
            <span class="font-medium text-sm">{tag.name}</span>
          </:col>
          <:col :let={tag} label="Color">
            <div class="flex items-center gap-2">
              <span
                :if={tag_color_style(tag.color)}
                class="h-5 w-5 shrink-0 rounded border border-base-300"
                style={tag_color_style(tag.color)}
              />
              <span class="font-mono text-xs">{tag.color || "-"}</span>
            </div>
          </:col>
          <:col :let={tag} label="Slug">
            <span class="font-mono text-xs break-all">{tag.slug}</span>
          </:col>
          <:col :let={tag} label="Updated">
            <span class="font-mono text-xs tabular-nums">{format_dt(tag.updated_at)}</span>
          </:col>
          <:col :let={tag} label="">
            <div class="flex items-center justify-end gap-1">
              <.dm_btn
                size="xs"
                variant="ghost"
                class="text-error"
                type="button"
                phx-click="delete"
                phx-value-id={tag.id}
                data-confirm="Delete this tag?"
                title="Delete"
              >
                <.dm_mdi name="trash-can-outline" class="w-3.5 h-3.5" />
              </.dm_btn>
            </div>
          </:col>
        </.dm_table>
      </div>
    </Layouts.app>
    """
  end
end
