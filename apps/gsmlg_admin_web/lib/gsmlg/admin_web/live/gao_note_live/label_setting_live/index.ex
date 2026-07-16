defmodule GSMLG.AdminWeb.GaoNoteLive.LabelSettingLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.LabelSetting
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:active_menu, "gao_note_label_settings")
     |> assign(:label_settings, AsyncResult.loading())
     |> assign(:form, label_setting_form())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote Labels")
     |> assign(:active_menu, "gao_note_label_settings")
     |> assign_label_settings_async()}
  end

  @impl true
  def handle_event("create", %{"gao_note_label_setting" => params}, socket) do
    case GaoNote.create_label_setting(params) do
      {:ok, _label_setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Label created")
         |> assign(:form, label_setting_form())
         |> assign_label_settings_async()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :form, to_form(%{changeset | action: :insert}, as: :gao_note_label_setting))}
    end
  end

  def handle_event("update", %{"id" => id, "gao_note_label_setting" => params}, socket) do
    label_setting = GaoNote.get_label_setting!(id)

    case GaoNote.update_label_setting(label_setting, params) do
      {:ok, _label_setting} ->
        {:noreply, assign_label_settings_async(socket) |> put_flash(:info, "Label updated")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Update failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case GaoNote.get_label_setting(id) do
      nil ->
        {:noreply, assign_label_settings_async(socket)}

      %LabelSetting{} = label_setting ->
        case GaoNote.delete_label_setting(label_setting) do
          {:ok, _label_setting} ->
            {:noreply, assign_label_settings_async(socket) |> put_flash(:info, "Label deleted")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
        end
    end
  end

  defp assign_label_settings_async(socket) do
    assign_async(
      socket,
      :label_settings,
      fn -> {:ok, %{label_settings: GaoNote.list_label_settings(limit: 200)}} end,
      reset: true
    )
  end

  defp label_setting_form do
    %LabelSetting{}
    |> GaoNote.change_label_setting()
    |> to_form(as: :gao_note_label_setting)
  end

  defp value_type_options do
    Enum.map(LabelSetting.value_types(), &{&1, &1})
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp label_color_style(color) when is_binary(color) do
    color = String.trim(color)

    if Regex.match?(~r/^#[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$/, color) do
      "background-color: #{color}"
    end
  end

  defp label_color_style(_color), do: nil

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
            <.dm_mdi name="label_setting-multiple-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote Labels</h1>
          </div>
          <.link patch={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
            </.dm_btn>
          </.link>
        </div>

        <.dm_form
          id="gao-note-label_setting-form"
          for={@form}
          phx-submit="create"
          class="grid gap-3 md:grid-cols-[1fr_150px_180px_1fr_auto]"
        >
          <.dm_input field={@form[:name]} label="Key" />
          <.dm_input field={@form[:color]} label="Color" placeholder="#1f6feb" />
          <.dm_select
            field={@form[:value_type]}
            label="Value Type"
            options={value_type_options()}
          />
          <.dm_input field={@form[:description]} label="Description" />
          <:actions>
            <button type="submit" class="btn btn-primary gap-2">
              <.dm_mdi name="plus" class="w-4 h-4" /> Add
            </button>
          </:actions>
        </.dm_form>

        <.dm_skeleton_table
          :if={async_loading?(@label_settings)}
          id="gao-note-label_settings-loading"
          rows={4}
          columns={6}
          animation="wave"
          loading_label="Loading GaoNote labels"
        />
        <div :if={async_failed?(@label_settings)} class="text-sm text-error">
          Unable to load labels.
        </div>

        <.dm_table
          :if={!async_loading?(@label_settings)}
          id="gao-note-label_settings-table"
          class="table-bordered table-compact"
          data={async_value(@label_settings, [])}
        >
          <:col :let={label_setting} label="Name">
            <span class="font-medium text-sm">{label_setting.name}</span>
          </:col>
          <:col :let={label_setting} label="Type">
            <span class="font-mono text-xs">{label_setting.value_type || "text"}</span>
          </:col>
          <:col :let={label_setting} label="Description">
            <span class="text-sm text-base-content/70">{label_setting.description || "-"}</span>
          </:col>
          <:col :let={label_setting} label="Color">
            <div class="flex items-center gap-2">
              <span
                :if={label_color_style(label_setting.color)}
                class="h-5 w-5 shrink-0 rounded border border-base-300"
                style={label_color_style(label_setting.color)}
              />
              <span class="font-mono text-xs">{label_setting.color || "-"}</span>
            </div>
          </:col>
          <:col :let={label_setting} label="Updated">
            <span class="font-mono text-xs tabular-nums">{format_dt(label_setting.updated_at)}</span>
          </:col>
          <:col :let={label_setting} label="">
            <div class="flex items-center justify-end gap-1">
              <.dm_btn
                size="xs"
                variant="ghost"
                class="text-error"
                type="button"
                phx-click="delete"
                phx-value-id={label_setting.id}
                data-confirm="Delete this label_setting?"
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
