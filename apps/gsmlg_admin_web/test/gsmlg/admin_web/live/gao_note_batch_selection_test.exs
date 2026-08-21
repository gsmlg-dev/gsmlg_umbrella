defmodule GSMLG.AdminWeb.GaoNoteBatchSelectionTest do
  use ExUnit.Case, async: true

  # Task 5 must browser-verify dialog open persistence, uninterrupted DELETE typing,
  # Tab/Shift+Tab containment, Escape/Cancel, focus return, and duplicate IDs once routed.

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.GaoNoteLive.{BatchActionComponents, BatchSelection}

  describe "BatchSelection" do
    test "toggle/2 adds and removes a row id" do
      assert MapSet.new(["note-1"]) == BatchSelection.toggle(MapSet.new(), "note-1")

      assert MapSet.new() ==
               BatchSelection.toggle(MapSet.new(["note-1"]), "note-1")
    end

    test "toggle_all/2 selects and clears all loaded ids" do
      loaded_ids = ["note-1", "note-2"]

      assert MapSet.new(loaded_ids) == BatchSelection.toggle_all(MapSet.new(), loaded_ids)

      assert MapSet.new() ==
               BatchSelection.toggle_all(MapSet.new(loaded_ids), loaded_ids)
    end

    test "toggle_all/2 preserves an existing hidden selection" do
      selected = MapSet.new(["hidden-note"])

      assert MapSet.new(["hidden-note", "note-1", "note-2"]) ==
               BatchSelection.toggle_all(selected, ["note-1", "note-2"])

      selected = MapSet.new(["hidden-note", "note-1", "note-2"])

      assert MapSet.new(["hidden-note"]) ==
               BatchSelection.toggle_all(selected, ["note-1", "note-2"])
    end

    test "state/2 reports mixed selection" do
      assert :mixed ==
               BatchSelection.state(MapSet.new(["note-1"]), ["note-1", "note-2"])
    end

    test "state/2 reports none for an empty loaded set" do
      assert :none == BatchSelection.state(MapSet.new(["note-1"]), [])
    end

    test "state/2 considers only loaded ids" do
      assert :none ==
               BatchSelection.state(MapSet.new(["hidden-note"]), ["note-1", "note-2"])

      assert :all ==
               BatchSelection.state(
                 MapSet.new(["hidden-note", "note-1", "note-2"]),
                 ["note-1", "note-2"]
               )
    end

    test "reconcile/2 removes stale ids" do
      selected = MapSet.new(["note-1", "stale-note"])

      assert MapSet.new(["note-1"]) ==
               BatchSelection.reconcile(selected, ["note-1", "note-2"])
    end
  end

  describe "BatchActionComponents" do
    test "selection_checkbox/1 renders an accessible mixed checkbox" do
      html =
        render_component(&BatchActionComponents.selection_checkbox/1,
          id: "select-all-notes",
          checked: true,
          state: :mixed,
          event: "toggle_all_notes",
          value_id: "loaded",
          label: "Select all loaded notes"
        )

      assert [input] = html |> fragment() |> Floki.find("#select-all-notes")

      assert {"input", attrs, []} = input
      assert {"type", "checkbox"} in attrs
      assert {"class", "checkbox checkbox-primary checkbox-sm"} in attrs
      assert {"checked", "checked"} in attrs
      assert {"aria-label", "Select all loaded notes"} in attrs
      assert {"aria-checked", "mixed"} in attrs
      assert {"data-state", "mixed"} in attrs
      assert {"phx-hook", "IndeterminateCheckbox"} in attrs
      assert {"phx-click", "toggle_all_notes"} in attrs
      assert {"phx-value-id", "loaded"} in attrs
    end

    test "renders every stable toolbar, modal, and destructive button id" do
      label_html = render_label_modal("add")

      notes_toolbar =
        render_component(&BatchActionComponents.notes_toolbar/1,
          selected_count: 2,
          clear_event: "clear_note_selection",
          label_modal_id: "gao-note-batch-label-modal",
          delete_modal_id: "gao-note-batch-delete-modal"
        )

      soft_delete =
        render_component(&BatchActionComponents.soft_delete_modal/1,
          selected_count: 2,
          error: nil
        )

      recycle_toolbar =
        render_component(&BatchActionComponents.recycle_toolbar/1,
          selected_count: 2,
          clear_event: "clear_recycle_selection",
          purge_modal_id: "gao-note-recycle-purge-modal"
        )

      purge = render_purge_modal("")

      assert_one_id(notes_toolbar, "gao-note-batch-toolbar")
      assert_one_id(label_html, "gao-note-batch-label-modal")
      assert_one_id(soft_delete, "gao-note-batch-delete-modal")
      assert_one_id(soft_delete, "gao-note-batch-delete-confirm")
      assert_one_id(recycle_toolbar, "gao-note-recycle-batch-toolbar")
      assert_one_id(purge, "gao-note-recycle-purge-modal")
      assert_one_id(purge, "gao-note-recycle-purge-confirm")
    end

    test "every modal preserves client state and installs the accessible dialog workaround" do
      modal_html = [
        {render_label_modal("add"), "gao-note-batch-label-modal"},
        {
          render_component(&BatchActionComponents.soft_delete_modal/1,
            selected_count: 2,
            error: nil
          ),
          "gao-note-batch-delete-modal"
        },
        {render_purge_modal(""), "gao-note-recycle-purge-modal"}
      ]

      for {html, id} <- modal_html do
        document = fragment(html)

        assert [modal] = Floki.find(document, "##{id}")
        assert Floki.attribute(modal, "phx-hook") == ["AccessibleDialog"]
        assert [mounted] = Floki.attribute(modal, "phx-mounted")
        assert mounted =~ "ignore_attrs"

        for attribute <- ~w(open role aria-modal aria-labelledby aria-label) do
          assert mounted =~ attribute
        end

        assert [_] = Floki.find(modal, "[data-dialog-initial-focus]")
      end
    end

    test "toolbars announce only the changing selected count" do
      toolbar_html = [
        render_component(&BatchActionComponents.notes_toolbar/1,
          selected_count: 2,
          clear_event: "clear_note_selection",
          label_modal_id: "gao-note-batch-label-modal",
          delete_modal_id: "gao-note-batch-delete-modal"
        ),
        render_component(&BatchActionComponents.recycle_toolbar/1,
          selected_count: 2,
          clear_event: "clear_recycle_selection",
          purge_modal_id: "gao-note-recycle-purge-modal"
        )
      ]

      for html <- toolbar_html do
        document = fragment(html)

        assert [] = Floki.find(document, "section[aria-live], section[role]")
        assert [status] = Floki.find(document, ~s(span[role="status"][aria-live="polite"]))
        assert status |> Floki.text() |> String.trim() == "2 selected"
      end
    end

    test "label_modal/1 renders only Add fields and a catalog-backed target selector" do
      html = render_label_modal("add")
      document = fragment(html)

      assert [_] = Floki.find(document, ~s(select[name="batch_label[action]"]))
      assert [_] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(input[name="batch_label[target_value]"]))
      assert [] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [] = Floki.find(document, ~s(input[name="batch_label[match_value]"]))
      assert [project_option] = Floki.find(document, ~s(option[value="label-project"]))
      assert project_option |> Floki.text() |> String.trim() == "Project"
      assert html =~ "Selected"
      assert html =~ "Matched"
      assert html =~ "Changed"
      assert html =~ "Unchanged"
      assert html =~ "Conflict"
      assert html =~ "Preview unavailable"
    end

    test "label_modal/1 renders its preview as a labelled description list" do
      document = "add" |> render_label_modal() |> fragment()

      assert [preview] = Floki.find(document, ~s(dl[aria-label="Batch preview"]))
      assert 5 = preview |> Floki.find("div") |> length()

      assert ["Selected", "Matched", "Changed", "Unchanged", "Conflict"] =
               preview
               |> Floki.find("dt")
               |> Enum.map(&(Floki.text(&1) |> String.trim()))

      assert 5 = preview |> Floki.find("dd") |> length()
    end

    test "label_modal/1 derives its action from the form instead of a separate assign" do
      html =
        render_component(&BatchActionComponents.label_modal/1,
          form: batch_label_form("delete"),
          label_options: [{"Project", "label-project"}],
          selected_count: 1,
          preview: nil,
          error: nil,
          valid?: true
        )

      document = fragment(html)

      assert [_] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
    end

    test "label_modal/1 defaults a missing form action to Add" do
      html =
        render_component(&BatchActionComponents.label_modal/1,
          form: batch_label_form(nil),
          label_options: [{"Project", "label-project"}],
          selected_count: 1,
          preview: nil,
          error: nil,
          valid?: true
        )

      document = fragment(html)

      assert [] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
    end

    test "label_modal/1 defaults an empty form action to Add" do
      document = "" |> render_label_modal() |> fragment()

      assert [] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
      assert [submit] = Floki.find(document, "#gao-note-batch-label-submit")
      assert submit |> Floki.text() |> String.trim() == "Add label"
    end

    test "label_modal/1 renders only Edit fields" do
      document = "edit" |> render_label_modal() |> fragment()

      assert [_] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(input[name="batch_label[match_value]"]))
      assert [_] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(input[name="batch_label[target_value]"]))
    end

    test "label_modal/1 renders only Delete fields" do
      document = "delete" |> render_label_modal() |> fragment()

      assert [_] = Floki.find(document, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert [_] = Floki.find(document, ~s(input[name="batch_label[match_value]"]))
      assert [] = Floki.find(document, ~s(select[name="batch_label[target_label_setting_id]"]))
      assert [] = Floki.find(document, ~s(input[name="batch_label[target_value]"]))
    end

    test "label_modal/1 never renders a raw arbitrary label key field" do
      for action <- ~w(add edit delete) do
        document = action |> render_label_modal() |> fragment()

        assert [] = Floki.find(document, ~s(input[name="batch_label[label_key]"]))
        assert [] = Floki.find(document, ~s(input[name="batch_label[target_key]"]))
        assert [] = Floki.find(document, ~s(input[name="batch_label[match_key]"]))
      end
    end

    test "purge_modal/1 enables confirmation only for exact DELETE" do
      assert [_] =
               ""
               |> render_purge_modal()
               |> fragment()
               |> Floki.find(
                 ~s(#gao-note-recycle-purge-form[phx-change="change_batch_purge_confirmation"])
               )

      for confirmation <- ["", "delete", "DELETE "] do
        assert [_] =
                 confirmation
                 |> render_purge_modal()
                 |> fragment()
                 |> Floki.find("#gao-note-recycle-purge-confirm[disabled]")
      end

      assert [] =
               "DELETE"
               |> render_purge_modal()
               |> fragment()
               |> Floki.find("#gao-note-recycle-purge-confirm[disabled]")
    end
  end

  defp render_label_modal(action) do
    form = batch_label_form(action)

    render_component(&BatchActionComponents.label_modal/1,
      form: form,
      label_options: [{"Project", "label-project"}, {"Type", "label-type"}],
      selected_count: 3,
      preview: %{selected: 3, matched: 2, changed: 1, unchanged: 1, conflict: 0},
      error: "Preview unavailable",
      valid?: true
    )
  end

  defp batch_label_form(action) do
    Phoenix.Component.to_form(
      %{
        "action" => action,
        "match_label_setting_id" => "",
        "match_value" => "",
        "target_label_setting_id" => "",
        "target_value" => ""
      },
      as: :batch_label
    )
  end

  defp render_purge_modal(confirmation) do
    form = Phoenix.Component.to_form(%{"confirmation" => confirmation}, as: :purge)

    render_component(&BatchActionComponents.purge_modal/1,
      form: form,
      selected_count: 2,
      error: nil
    )
  end

  defp fragment(html), do: Floki.parse_fragment!(html)

  defp assert_one_id(html, id) do
    assert [_] = html |> fragment() |> Floki.find("##{id}")
  end
end
