defmodule GSMLG.AdminWeb.StorageLive.FolderTreeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.StorageLive.FolderTree
  alias GSMLG.Storage.Inventory

  test "leaf actions open native dialogs separately from navigation" do
    document = render_tree()
    leaf_id = folder_id("parent/leaf/")
    parent_id = folder_id("parent/")

    assert [trigger] =
             Floki.find(document, "##{leaf_id}-actions-popover-trigger[aria-haspopup=menu]")

    assert Floki.text(trigger) =~ "Actions for parent/leaf/"
    assert Floki.find(document, "##{parent_id}-actions-popover-trigger") == []
    assert Floki.find(document, "a button") == []

    for {action, dialog_suffix} <- [{"Edit", "rename"}, {"Delete", "delete"}] do
      assert [item] =
               Floki.find(
                 document,
                 "##{leaf_id}-actions-popover button[role=menuitem][command=show-modal][commandfor='#{leaf_id}-#{dialog_suffix}-dialog']"
               )

      assert Floki.text(item) =~ action
      assert [_dialog] = Floki.find(document, "dialog##{leaf_id}-#{dialog_suffix}-dialog")
    end

    assert [_input] =
             Floki.find(
               document,
               "##{leaf_id}-rename-form input[name='folder[name]'][value=leaf][required][autofocus]"
             )

    assert [_cancel] =
             Floki.find(document, "##{leaf_id}-delete-form button[command=close][autofocus]")
  end

  test "forms preserve exact encoded prefixes and backend identity without duplicate IDs" do
    prefix = "parent/line\r\n日本語 /"
    document = render_tree([leaf(prefix, "line\r\n日本語 "), leaf("other/", "other")])

    for node_prefix <- [prefix, "other/"], action <- ["rename", "delete"] do
      form_id = folder_id(node_prefix) <> "-#{action}-form"
      assert [form] = Floki.find(document, "##{form_id}[phx-submit='#{action}_folder']")

      assert Floki.attribute(Floki.find(form, "input[name='folder[prefix]']"), "value") ==
               [Inventory.encode_key(node_prefix)]

      assert Floki.attribute(Floki.find(form, "input[name='folder[backend]']"), "value") ==
               ["backend-test"]
    end

    ids = document |> Floki.find("[id]") |> Floki.attribute("id")
    assert length(ids) == length(Enum.uniq(ids))
  end

  test "actions are absent without a configured backend" do
    document = render_tree(default_nodes(), backend_id: nil)

    assert Floki.find(document, "[aria-haspopup=menu]") == []
    assert Floki.find(document, "dialog") == []
  end

  test "shows operation errors in the matching dialog and explicit recursive delete warning" do
    document =
      render_tree(default_nodes(),
        folder_errors: %{
          {"parent/leaf/", :rename} => "Folder already exists.",
          {"parent/leaf/", :delete} => "A note references this folder."
        }
      )

    leaf_id = folder_id("parent/leaf/")

    assert Floki.text(Floki.find(document, "##{leaf_id}-rename-dialog [role=alert]")) ==
             "Folder already exists."

    assert Floki.text(Floki.find(document, "##{leaf_id}-delete-dialog [role=alert]")) ==
             "A note references this folder."

    warning = Floki.text(Floki.find(document, "##{leaf_id}-delete-dialog"))
    assert warning =~ "parent/leaf/"
    assert warning =~ "all 3 files, including subfolders"
    assert warning =~ "This cannot be undone."
    refute warning =~ "Only empty folders"
  end

  test "empty folders still show the permanent deletion confirmation" do
    document = render_tree([%{leaf("empty/", "empty") | count: 0}])
    warning = Floki.text(Floki.find(document, "dialog[id$='-delete-dialog']"))
    assert warning =~ "all 0 files, including subfolders"
    assert warning =~ "This cannot be undone."
  end

  test "busy mutations disable submissions while keeping cancel available" do
    document = render_tree(default_nodes(), busy: true)
    assert length(Floki.find(document, "button[type=submit][disabled]")) == 2
    assert Floki.find(document, "button[command=close][disabled]") == []
  end

  defp render_tree(nodes \\ default_nodes(), opts \\ []) do
    assigns =
      Keyword.merge(
        [
          nodes: nodes,
          prefix: "",
          expanded: MapSet.new(["parent/"]),
          total_files: 3,
          backend_id: "backend-test"
        ],
        opts
      )

    render_component(&FolderTree.folder_tree/1, assigns)
    |> Floki.parse_fragment!()
  end

  defp default_nodes do
    [%{prefix: "parent/", name: "parent", count: 3, children: [leaf("parent/leaf/", "leaf")]}]
  end

  defp leaf(prefix, name), do: %{prefix: prefix, name: name, count: 3, children: []}
  defp folder_id(prefix), do: "storage-folder-" <> Inventory.encode_key(prefix)
end
