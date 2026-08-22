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
     |> assign(:category_groups, AsyncResult.loading())
     |> assign(:category_draft, nil)
     |> assign(:category_form, category_form())
     |> assign(:form, label_setting_form())}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply,
     socket
     |> assign(:page_title, "GaoNote Labels")
     |> assign(:active_menu, "gao_note_label_settings")
     |> assign_label_settings_async()
     |> assign_category_groups_async()}
  end

  @impl true
  def handle_event("category_changed", %{"category" => params}, socket) do
    {:noreply, assign(socket, :category_form, category_form(params))}
  end

  def handle_event("add_category", _params, socket) do
    params = socket.assigns.category_form.params
    label_setting_id = Map.get(params, "label_setting_id", "")
    value = params |> Map.get("value", "") |> String.trim() |> blank_to_nil()

    with {:ok, label_setting} <- find_category_label(socket, label_setting_id),
         {:ok, categories} <- append_category(socket, label_setting, value) do
      {:noreply,
       socket
       |> clear_flash(:error)
       |> assign(:category_draft, categories)
       |> assign(:category_form, category_form())}
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event(
        "remove_category",
        %{"label_setting_id" => label_setting_id, "value" => value},
        socket
      )
      when is_binary(label_setting_id) and is_binary(value) do
    categories = current_categories(socket)
    value = value |> String.trim() |> blank_to_nil()

    case Enum.find_index(categories, fn category ->
           category.label_setting_id == label_setting_id and category.value == value
         end) do
      nil ->
        {:noreply, unavailable_category_selection(socket)}

      position ->
        {:noreply,
         socket
         |> clear_flash(:error)
         |> assign(:category_draft, List.delete_at(categories, position))}
    end
  end

  def handle_event("remove_category", _params, socket) do
    {:noreply, unavailable_category_selection(socket)}
  end

  def handle_event("save_categories", _params, socket) do
    selectors =
      Enum.map(current_categories(socket), fn category ->
        %{label_setting_id: category.label_setting_id, value: category.value}
      end)

    case GaoNote.save_category_settings(selectors) do
      {:ok, _categories} ->
        {:noreply,
         socket
         |> put_flash(:info, "Category labels saved.")
         |> clear_flash(:error)
         |> assign(:category_draft, nil)
         |> assign(:category_form, category_form())
         |> assign_label_settings_async()
         |> assign_category_groups_async()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, category_save_error(reason, socket))}
    end
  end

  @impl true
  def handle_event("create", %{"gao_note_label_setting" => params}, socket) do
    case GaoNote.create_label_setting(params) do
      {:ok, _label_setting} ->
        {:noreply,
         socket
         |> put_flash(:info, "Label created")
         |> assign(:form, label_setting_form())
         |> assign_label_settings_async()
         |> assign_category_groups_async()
         |> push_event("close-dialog", %{id: "gao-note-label-setting-create-modal"})}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(
           socket,
           :form,
           to_form(%{changeset | action: :insert},
             as: :gao_note_label_setting,
             id: "gao-note-label-setting-create"
           )
         )}
    end
  end

  def handle_event(
        "update",
        %{"label_setting_id" => id, "gao_note_label_setting" => params},
        socket
      ) do
    label_setting = GaoNote.get_label_setting!(id)

    case GaoNote.update_label_setting(label_setting, params) do
      {:ok, _label_setting} ->
        {:noreply,
         socket
         |> assign_label_settings_async()
         |> assign_category_groups_async()
         |> put_flash(:info, "Label updated")
         |> push_event("close-dialog", %{id: edit_modal_id(id)})}

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
            {:noreply, put_flash(socket, :error, delete_error(reason))}
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

  defp assign_category_groups_async(socket) do
    assign_async(
      socket,
      :category_groups,
      fn -> {:ok, %{category_groups: GaoNote.list_category_groups()}} end,
      reset: true
    )
  end

  defp category_form(params \\ %{}) do
    params = %{
      "label_setting_id" => Map.get(params, "label_setting_id", ""),
      "value" => Map.get(params, "value", "")
    }

    to_form(params, as: :category, id: "gao-note-category")
  end

  defp label_setting_form do
    label_setting_form(%LabelSetting{})
  end

  defp label_setting_form(%LabelSetting{} = label_setting) do
    form_id =
      case label_setting.id do
        nil -> "gao-note-label-setting-create"
        id -> "gao-note-label-setting-edit-#{id}"
      end

    label_setting
    |> GaoNote.change_label_setting()
    |> to_form(as: :gao_note_label_setting, id: form_id)
  end

  defp edit_modal_id(id), do: "gao-note-label-setting-edit-modal-#{id}"

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

  defp async_ready?(%AsyncResult{ok?: true, failed: nil, loading: nil}), do: true
  defp async_ready?(_result), do: false

  defp category_label_options(label_settings) do
    label_settings
    |> async_value([])
    |> Enum.map(&{&1.id, LabelSetting.normalized_key(&1.name)})
  end

  defp displayed_categories(nil, category_groups) do
    category_groups
    |> async_value([])
    |> Enum.map(fn group ->
      %{
        label_setting_id: group.label_setting_id,
        key: group.key,
        value: group.configured_value,
        selector: group.selector
      }
    end)
  end

  defp displayed_categories(categories, _category_groups), do: categories

  defp current_categories(socket) do
    displayed_categories(socket.assigns.category_draft, socket.assigns.category_groups)
  end

  defp find_category_label(_socket, ""), do: {:error, "Choose a label key."}

  defp find_category_label(socket, label_setting_id) do
    case Enum.find(async_value(socket.assigns.label_settings, []), &(&1.id == label_setting_id)) do
      nil -> {:error, "The selected label is unavailable. Reload the page and try again."}
      label_setting -> {:ok, label_setting}
    end
  end

  defp append_category(socket, label_setting, value) do
    categories = current_categories(socket)

    if Enum.any?(categories, &(&1.label_setting_id == label_setting.id and &1.value == value)) do
      {:error, "That category selector is already selected."}
    else
      key = LabelSetting.normalized_key(label_setting.name)
      selector = if is_nil(value), do: key, else: "#{key}=#{value}"

      {:ok,
       categories ++
         [
           %{
             label_setting_id: label_setting.id,
             key: key,
             value: value,
             selector: selector
           }
         ]}
    end
  end

  defp category_save_error({:invalid_category_value, label_setting_id, errors}, socket) do
    name = category_label_name(socket, label_setting_id)
    "Category value for #{name} #{Enum.join(errors, ", ")}."
  end

  defp category_save_error({:duplicate_category_selector, _label_setting_id, _value}, _socket),
    do: "That category selector is already selected."

  defp category_save_error({:unknown_category_label, _label_setting_id}, _socket),
    do: "A selected label no longer exists. Reload the page and try again."

  defp category_save_error({:invalid_category_selector, index, reason}, _socket),
    do: "Category #{index + 1} is invalid: #{humanize_reason(reason)}."

  defp category_save_error(:category_settings_must_be_a_list, _socket),
    do: "Category labels must be an ordered list."

  defp category_save_error(%Ecto.Changeset{} = changeset, _socket),
    do: "Category labels could not be saved: #{inspect(changeset.errors)}"

  defp category_save_error(reason, _socket),
    do: "Category labels could not be saved: #{inspect(reason)}"

  defp category_label_name(socket, label_setting_id) do
    socket.assigns.label_settings
    |> async_value([])
    |> Enum.find_value("selected label", fn setting ->
      if setting.id == label_setting_id, do: LabelSetting.normalized_key(setting.name)
    end)
  end

  defp humanize_reason(:invalid_label_setting_id), do: "choose an existing label"
  defp humanize_reason(:invalid_value), do: "the exact value must be text"
  defp humanize_reason(:must_be_a_map), do: "the selector has an invalid shape"
  defp humanize_reason(reason), do: inspect(reason)

  defp delete_error({:category_label_in_use, %{message: message}}), do: message
  defp delete_error(reason), do: "Delete failed: #{inspect(reason)}"

  defp unavailable_category_selection(socket) do
    put_flash(socket, :error, "That category selection is no longer available.")
  end

  defp category_delete_instruction do
    "Remove every category using this label from Category labels before deleting it."
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

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
          <div class="flex items-center gap-2">
            <.dm_modal
              id="gao-note-label-setting-create-modal"
              size="md"
              dialog_label="Create label"
            >
              <:trigger :let={dialog_id}>
                <.dm_btn
                  id="gao-note-label-setting-create"
                  size="sm"
                  variant="primary"
                  type="button"
                  onclick={"document.getElementById('#{dialog_id}').show()"}
                >
                  <.dm_mdi name="plus" class="w-4 h-4" /> New Label
                </.dm_btn>
              </:trigger>
              <:title>Create label</:title>
              <:body>
                <.dm_form
                  id="gao-note-label_setting-form"
                  for={@form}
                  phx-submit="create"
                  class="grid gap-3"
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
                    <div class="flex justify-end gap-2">
                      <.dm_btn
                        type="button"
                        variant="ghost"
                        onclick="document.getElementById('gao-note-label-setting-create-modal').close()"
                      >
                        Cancel
                      </.dm_btn>
                      <button type="submit" class="btn btn-primary gap-2">
                        <.dm_mdi name="plus" class="w-4 h-4" /> Create
                      </button>
                    </div>
                  </:actions>
                </.dm_form>
              </:body>
            </.dm_modal>

            <.link patch={~p"/gao_notes/notes"}>
              <.dm_btn size="sm" variant="ghost">
                <.dm_mdi name="notebook-outline" class="w-4 h-4" /> Notes
              </.dm_btn>
            </.link>
          </div>
        </div>

        <.dm_card
          id="gao-note-category-settings"
          variant="bordered"
          class="bg-surface-container text-on-surface"
          body_class="grid gap-4"
        >
          <:title>
            <div class="grid gap-1">
              <h2 class="text-lg font-semibold">Category labels</h2>
              <p class="text-sm font-normal text-on-surface-variant">
                Choose key-wide or exact label selectors for the dashboard.
              </p>
            </div>
          </:title>

          <.dm_skeleton_form
            :if={async_loading?(@label_settings) or async_loading?(@category_groups)}
            id="gao-note-category-settings-loading"
            fields={2}
            loading_label="Loading Category labels"
          />

          <div
            :if={async_failed?(@label_settings) or async_failed?(@category_groups)}
            class="text-sm text-error"
          >
            Category labels are unavailable.
          </div>

          <div
            :if={async_ready?(@label_settings) and async_ready?(@category_groups)}
            class="grid gap-4"
          >
            <.dm_form
              id="gao-note-category-form"
              for={@category_form}
              phx-change="category_changed"
              class="grid gap-3 lg:grid-cols-[minmax(12rem,1fr)_minmax(12rem,1fr)_auto] lg:items-end"
            >
              <.dm_select
                field={@category_form[:label_setting_id]}
                label="Label key"
                prompt="Choose a label"
                options={category_label_options(@label_settings)}
              />
              <.dm_input
                field={@category_form[:value]}
                label="Exact value (optional)"
                placeholder="Blank selects every value"
              />
              <.dm_btn
                id="gao-note-category-add"
                type="button"
                variant="secondary"
                phx-click="add_category"
              >
                <.dm_mdi name="plus" class="h-4 w-4" /> Add
              </.dm_btn>
            </.dm_form>

            <div id="gao-note-category-selection" class="flex min-h-8 flex-wrap gap-2">
              <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#141 --%>
              <button
                :for={category <- displayed_categories(@category_draft, @category_groups)}
                type="button"
                class="chip chip-secondary chip-sm"
                phx-click="remove_category"
                phx-value-label_setting_id={category.label_setting_id}
                phx-value-value={category.value || ""}
                data-selector={category.selector}
                aria-label={"Remove category #{category.selector}"}
              >
                {category.selector} <span aria-hidden="true">×</span>
              </button>
              <span
                :if={displayed_categories(@category_draft, @category_groups) == []}
                class="text-sm text-on-surface-variant"
              >
                No categories selected.
              </span>
            </div>

            <div class="flex justify-end">
              <.dm_btn
                id="gao-note-category-save"
                type="button"
                variant="primary"
                phx-click="save_categories"
              >
                Save Category labels
              </.dm_btn>
            </div>
          </div>
        </.dm_card>

        <.dm_skeleton_table
          :if={async_loading?(@label_settings)}
          id="gao-note-label_settings-loading"
          rows={4}
          columns={7}
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
          <:col :let={label_setting} label="Notes">
            <span class="font-mono text-xs tabular-nums">{label_setting.note_count}</span>
          </:col>
          <:col :let={label_setting} label="Updated">
            <span class="font-mono text-xs tabular-nums">{format_dt(label_setting.updated_at)}</span>
          </:col>
          <:col :let={label_setting} label="">
            <div class="flex items-center justify-end gap-1">
              <% edit_form = label_setting_form(label_setting) %>
              <% delete_instruction_id =
                "gao-note-label-setting-delete-instruction-#{label_setting.id}" %>
              <.dm_modal
                id={edit_modal_id(label_setting.id)}
                size="md"
                dialog_label={"Edit label #{label_setting.name}"}
              >
                <:trigger :let={dialog_id}>
                  <.dm_btn
                    id={"gao-note-label-setting-edit-#{label_setting.id}"}
                    size="xs"
                    variant="ghost"
                    type="button"
                    title="Edit"
                    onclick={"document.getElementById('#{dialog_id}').show()"}
                  >
                    <.dm_mdi name="pencil-outline" class="w-3.5 h-3.5" />
                  </.dm_btn>
                </:trigger>
                <:title>Edit label</:title>
                <:body>
                  <.dm_form
                    id={"gao-note-label-setting-edit-form-#{label_setting.id}"}
                    for={edit_form}
                    phx-submit="update"
                    class="grid gap-3"
                  >
                    <input
                      type="hidden"
                      name="label_setting_id"
                      value={label_setting.id}
                    />
                    <.dm_input field={edit_form[:name]} label="Key" />
                    <.dm_input
                      field={edit_form[:color]}
                      label="Color"
                      placeholder="#1f6feb"
                    />
                    <.dm_select
                      field={edit_form[:value_type]}
                      label="Value Type"
                      options={value_type_options()}
                    />
                    <.dm_input field={edit_form[:description]} label="Description" />
                    <:actions>
                      <div class="flex justify-end gap-2">
                        <.dm_btn
                          type="button"
                          variant="ghost"
                          onclick={"document.getElementById('#{edit_modal_id(label_setting.id)}').close()"}
                        >
                          Cancel
                        </.dm_btn>
                        <button type="submit" class="btn btn-primary">Save</button>
                      </div>
                    </:actions>
                  </.dm_form>
                </:body>
              </.dm_modal>

              <span
                id={"gao-note-label-setting-delete-help-#{label_setting.id}"}
                class="inline-flex"
                tabindex={if label_setting.category_count > 0, do: "0"}
                aria-describedby={if label_setting.category_count > 0, do: delete_instruction_id}
              >
                <.dm_btn
                  id={"gao-note-label-setting-delete-#{label_setting.id}"}
                  size="xs"
                  variant="ghost"
                  class="text-error"
                  type="button"
                  disabled={label_setting.category_count > 0}
                  phx-click={if label_setting.category_count > 0, do: nil, else: "delete"}
                  phx-value-id={if label_setting.category_count > 0, do: nil, else: label_setting.id}
                  data-confirm={
                    if label_setting.category_count > 0,
                      do: nil,
                      else: "Delete this label_setting?"
                  }
                  title={
                    if label_setting.category_count > 0,
                      do: category_delete_instruction(),
                      else: "Delete"
                  }
                >
                  <.dm_mdi name="trash-can-outline" class="w-3.5 h-3.5" />
                </.dm_btn>
              </span>
              <span
                :if={label_setting.category_count > 0}
                id={delete_instruction_id}
                class="sr-only"
              >
                {category_delete_instruction()}
              </span>
            </div>
          </:col>
        </.dm_table>
      </div>
    </Layouts.app>
    """
  end
end
