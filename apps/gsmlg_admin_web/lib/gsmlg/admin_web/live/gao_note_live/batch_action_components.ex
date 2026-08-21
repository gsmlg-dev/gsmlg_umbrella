defmodule GSMLG.AdminWeb.GaoNoteLive.BatchActionComponents do
  @moduledoc false

  use GSMLG.AdminWeb, :html

  # Task 5 must browser-verify dialog open persistence, uninterrupted DELETE typing,
  # Tab/Shift+Tab containment, Escape/Cancel, focus return, and duplicate IDs once routed.

  attr :id, :string, required: true
  attr :checked, :boolean, default: false
  attr :state, :atom, default: :none, values: [:none, :mixed, :all]
  attr :event, :string, required: true
  attr :value_id, :string, default: nil
  attr :label, :string, required: true

  def selection_checkbox(assigns) do
    ~H"""
    <input
      type="checkbox"
      id={@id}
      class="checkbox checkbox-primary checkbox-sm"
      checked={@checked}
      aria-label={@label}
      aria-checked={checkbox_aria_checked(@state, @checked)}
      data-state={@state}
      phx-hook="IndeterminateCheckbox"
      phx-click={@event}
      phx-value-id={@value_id}
    />
    """
  end

  attr :selected_count, :integer, required: true
  attr :clear_event, :string, required: true
  attr :label_modal_id, :string, required: true
  attr :delete_modal_id, :string, required: true

  def notes_toolbar(assigns) do
    ~H"""
    <section
      id="gao-note-batch-toolbar"
      class="flex flex-wrap items-center gap-3 rounded-xl bg-surface-container-high p-3 text-on-surface"
    >
      <span class="text-sm font-medium" role="status" aria-live="polite">
        {@selected_count} selected
      </span>
      <div class="flex flex-wrap items-center gap-2">
        <.dm_btn type="button" size="sm" variant="ghost" phx-click={@clear_event}>
          Clear
        </.dm_btn>
        <.dm_btn
          type="button"
          size="sm"
          variant="secondary"
          onclick={show_dialog(@label_modal_id)}
        >
          Edit labels
        </.dm_btn>
        <.dm_btn
          type="button"
          size="sm"
          variant="error"
          onclick={show_dialog(@delete_modal_id)}
        >
          Delete selected
        </.dm_btn>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :label_options, :list, required: true
  attr :selected_count, :integer, required: true
  attr :preview, :map, default: nil
  attr :error, :string, default: nil
  attr :valid?, :boolean, default: false

  def label_modal(assigns) do
    assigns =
      assigns
      |> assign(
        :normalized_action,
        normalize_action(Phoenix.HTML.Form.input_value(assigns.form, :action) || "add")
      )
      |> assign(:select_options, label_select_options(assigns.label_options))

    ~H"""
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#150 --%>
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#143 --%>
    <.dm_modal
      id="gao-note-batch-label-modal"
      size="md"
      class="bg-surface-container-highest text-on-surface"
      dialog_label="Edit selected note labels"
      phx-mounted={
        JS.ignore_attributes(["open", "role", "aria-modal", "aria-labelledby", "aria-label"])
      }
      phx-hook="AccessibleDialog"
    >
      <:title>Edit labels for {@selected_count} selected notes</:title>
      <:body class="grid gap-4">
        <.dm_alert :if={@error} variant="error">{@error}</.dm_alert>

        <dl
          :if={@preview}
          class="grid grid-cols-2 gap-3 sm:grid-cols-5"
          aria-label="Batch preview"
        >
          <div :for={{label, value, class} <- preview_items(@preview)} class="grid gap-1">
            <dt class="text-xs text-on-surface-variant">{label}</dt>
            <dd class={["text-sm font-semibold", class]}>{value}</dd>
          </div>
        </dl>

        <.dm_form
          id="gao-note-batch-label-form"
          for={@form}
          phx-change="change_batch_label_action"
          phx-submit="submit_batch_label"
          class="grid gap-4"
        >
          <.dm_select
            field={@form[:action]}
            label="Action"
            options={[{"add", "Add"}, {"edit", "Edit"}, {"delete", "Delete"}]}
          />

          <div :if={@normalized_action in [:edit, :delete]} class="grid gap-4">
            <.dm_select
              field={@form[:match_label_setting_id]}
              label="Match label"
              prompt="Choose a label"
              options={@select_options}
            />
            <.dm_input
              field={@form[:match_value]}
              label="Match value (optional)"
              placeholder="Blank matches every value"
            />
          </div>

          <div :if={@normalized_action in [:add, :edit]} class="grid gap-4">
            <.dm_select
              field={@form[:target_label_setting_id]}
              label="Target label"
              prompt="Choose a label"
              options={@select_options}
            />
            <.dm_input field={@form[:target_value]} label="Target value" />
          </div>

          <:actions>
            <div class="flex flex-wrap justify-end gap-2">
              <.dm_btn
                type="button"
                variant="ghost"
                onclick={close_dialog("gao-note-batch-label-modal")}
                data-dialog-initial-focus
              >
                Cancel
              </.dm_btn>
              <.dm_btn
                id="gao-note-batch-label-submit"
                type="submit"
                variant={label_submit_variant(@normalized_action)}
                disabled={!@valid?}
              >
                {label_submit_text(@normalized_action)}
              </.dm_btn>
            </div>
          </:actions>
        </.dm_form>
      </:body>
    </.dm_modal>
    """
  end

  attr :selected_count, :integer, required: true
  attr :error, :string, default: nil

  def soft_delete_modal(assigns) do
    ~H"""
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#150 --%>
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#143 --%>
    <.dm_modal
      id="gao-note-batch-delete-modal"
      size="sm"
      class="bg-surface-container-highest text-on-surface"
      dialog_label="Move selected notes to the Recycle Bin"
      phx-mounted={
        JS.ignore_attributes(["open", "role", "aria-modal", "aria-labelledby", "aria-label"])
      }
      phx-hook="AccessibleDialog"
    >
      <:title>Move selected notes?</:title>
      <:body class="grid gap-3">
        <.dm_alert :if={@error} variant="error">{@error}</.dm_alert>
        <p>Move {@selected_count} selected notes to the Recycle Bin?</p>
        <p class="text-sm text-on-surface-variant">
          You can restore these notes later from the Recycle Bin.
        </p>
      </:body>
      <:footer>
        <div class="flex flex-wrap justify-end gap-2">
          <.dm_btn
            type="button"
            variant="ghost"
            onclick={close_dialog("gao-note-batch-delete-modal")}
            data-dialog-initial-focus
          >
            Cancel
          </.dm_btn>
          <.dm_btn
            id="gao-note-batch-delete-confirm"
            type="button"
            variant="error"
            phx-click="batch_delete_notes"
          >
            Move to Recycle Bin
          </.dm_btn>
        </div>
      </:footer>
    </.dm_modal>
    """
  end

  attr :selected_count, :integer, required: true
  attr :clear_event, :string, required: true
  attr :purge_modal_id, :string, required: true

  def recycle_toolbar(assigns) do
    ~H"""
    <section
      id="gao-note-recycle-batch-toolbar"
      class="flex flex-wrap items-center gap-3 rounded-xl bg-surface-container-high p-3 text-on-surface"
    >
      <span class="text-sm font-medium" role="status" aria-live="polite">
        {@selected_count} selected
      </span>
      <div class="flex flex-wrap items-center gap-2">
        <.dm_btn type="button" size="sm" variant="ghost" phx-click={@clear_event}>
          Clear
        </.dm_btn>
        <.dm_btn
          type="button"
          size="sm"
          variant="error"
          onclick={show_dialog(@purge_modal_id)}
        >
          Delete selected permanently
        </.dm_btn>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :selected_count, :integer, required: true
  attr :error, :string, default: nil

  def purge_modal(assigns) do
    assigns = assign(assigns, :confirmation_valid?, purge_confirmation_valid?(assigns.form))

    ~H"""
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#150 --%>
    <%!-- WORKAROUND(upstream): duskmoon-dev/phoenix-duskmoon-ui#143 --%>
    <.dm_modal
      id="gao-note-recycle-purge-modal"
      size="sm"
      class="bg-surface-container-highest text-on-surface"
      dialog_label="Permanently delete selected notes"
      phx-mounted={
        JS.ignore_attributes(["open", "role", "aria-modal", "aria-labelledby", "aria-label"])
      }
      phx-hook="AccessibleDialog"
    >
      <:title>Permanently delete selected notes?</:title>
      <:body class="grid gap-4">
        <.dm_alert :if={@error} variant="error">{@error}</.dm_alert>
        <p>
          Permanently delete {@selected_count} selected notes and their attachments? This cannot be
          restored.
        </p>
        <p class="text-sm text-on-surface-variant">
          Attachment storage deletion runs asynchronously after the notes are removed.
        </p>

        <.dm_form
          id="gao-note-recycle-purge-form"
          for={@form}
          phx-change="change_batch_purge_confirmation"
          phx-submit="batch_purge_notes"
          class="grid gap-4"
        >
          <.dm_input
            field={@form[:confirmation]}
            label="Type DELETE to confirm"
            autocomplete="off"
          />
          <:actions>
            <div class="flex flex-wrap justify-end gap-2">
              <.dm_btn
                type="button"
                variant="ghost"
                onclick={close_dialog("gao-note-recycle-purge-modal")}
                data-dialog-initial-focus
              >
                Cancel
              </.dm_btn>
              <.dm_btn
                id="gao-note-recycle-purge-confirm"
                type="submit"
                variant="error"
                disabled={!@confirmation_valid?}
              >
                Delete permanently
              </.dm_btn>
            </div>
          </:actions>
        </.dm_form>
      </:body>
    </.dm_modal>
    """
  end

  defp checkbox_aria_checked(:mixed, _checked), do: "mixed"
  defp checkbox_aria_checked(_state, checked), do: to_string(checked)

  defp normalize_action(action) when is_binary(action) do
    case String.downcase(action) do
      "add" -> :add
      "edit" -> :edit
      "delete" -> :delete
      _other -> :unknown
    end
  end

  defp label_select_options(options) do
    Enum.map(options, fn {name, id} -> {id, name} end)
  end

  defp preview_items(preview) do
    [
      {"Selected", Map.get(preview, :selected, 0), nil},
      {"Matched", Map.get(preview, :matched, 0), nil},
      {"Changed", Map.get(preview, :changed, 0), nil},
      {"Unchanged", Map.get(preview, :unchanged, 0), "text-on-surface-variant"},
      {"Conflict", Map.get(preview, :conflict, 0), "text-error"}
    ]
  end

  defp label_submit_variant(:delete), do: "error"
  defp label_submit_variant(_action), do: "primary"

  defp label_submit_text(:add), do: "Add label"
  defp label_submit_text(:edit), do: "Edit labels"
  defp label_submit_text(:delete), do: "Delete labels"
  defp label_submit_text(:unknown), do: "Apply label action"

  defp purge_confirmation_valid?(form) do
    Phoenix.HTML.Form.input_value(form, :confirmation) == "DELETE"
  end

  defp show_dialog(id), do: "document.getElementById('#{id}').show()"
  defp close_dialog(id), do: "document.getElementById('#{id}').close()"
end
