defmodule GSMLG.AdminWeb.GaoNoteLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Asset, Log, MCPSetting, Note, Reference, Tag, Tagging}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @secret_key_base String.duplicate("a", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    Repo.delete_all(MCPSetting)
    Repo.delete_all(Log)
    Repo.delete_all(Asset)
    Repo.delete_all(Reference)
    Repo.delete_all(Tagging)
    Repo.delete_all(Tag)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn, user: user}
  end

  test "unauthenticated users cannot access GaoNote admin", %{conn: _conn} do
    conn = Phoenix.ConnTest.build_conn() |> with_secret_key_base()
    {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/gao_notes/notes")
  end

  test "admin can list notes", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Admin List Note",
                 description: "Admin description",
                 content: "Admin content",
                 creator: "Admin User",
                 tags: ["Admin Tag", "MCP Tag"]
               },
               user
             )

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes")

    assert html =~ "GaoNote"
    assert html =~ ~s(id="gao-note-table-loading")
    assert html =~ ~s(aria-label="Loading GaoNote notes")
    refute html =~ "Loading notes"

    html = render_async(view)

    assert html =~ note.title
    assert html =~ "Admin User"
    assert html =~ "Admin Tag"
    assert html =~ "MCP Tag"
    refute html =~ ~s(id="gao-note-table-loading")
    refute html =~ "Description"
    refute html =~ "Admin description"
  end

  test "admin can create a note", %{conn: conn} do
    assert {:ok, _tag} = GaoNote.create_tag(%{name: "Existing Tag"})

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/new")

    refute html =~ "Slug"
    refute html =~ "Status"
    refute html =~ "Visibility"
    assert html =~ "Tags"
    assert html =~ "Loading tags"

    html = render_async(view)

    assert html =~ "Existing Tag"
    assert html =~ "<el-dm-markdown-input"
    assert html =~ ~s(name="gao_note[content]")
    refute html =~ ~s(<textarea)
    assert html =~ ~s(id="gao-note-tags")
    assert html =~ ~s(<button type="submit")
    refute html =~ ~s(<el-dm-button variant="primary" class="" style="" type="submit")

    render_change(view, "tag_input_changed", %{"tag_input" => "New Live Tag"})
    assert render_click(view, "add_tag_option", %{"name" => "New Live Tag"}) =~ "New Live Tag"

    assert render_click(view, "set_tags", %{"tags" => ["Existing Tag", "New Live Tag"]}) =~
             "Existing Tag"

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Created From LiveView",
        "description" => "",
        "creator" => "LiveView Admin",
        "content" => "Created content",
        "tags" => ["Existing Tag", "New Live Tag"]
      }
    })

    assert [
             %Note{
               title: "Created From LiveView",
               description: "",
               creator: "LiveView Admin",
               content: "Created content"
             } = note
           ] =
             GaoNote.list_notes(search: "Created From LiveView")

    assert Enum.map(note.tags, & &1.slug) |> Enum.sort() == ["existing-tag", "new-live-tag"]
    assert_patch(view, ~p"/gao_notes/notes/#{note.id}")
  end

  test "admin sees validation errors when note creation is invalid", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)

    html =
      render_submit(view, "save", %{
        "gao_note" => %{
          "title" => "",
          "description" => "",
          "content" => ""
        }
      })

    assert html =~ "can&#39;t be blank"
    assert html =~ ~s(id="gao_note_title-errors")
    assert html =~ ~s(id="gao_note_content-errors")
    refute html =~ ~s(id="gao_note_description-errors")
  end

  test "admin can edit a note with the markdown input", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Editable Markdown Note",
                 content: "Original markdown"
               },
               user
             )

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    html = render_async(view)

    assert html =~ "<el-dm-markdown-input"
    assert html =~ ~s(name="gao_note[content]")
    refute html =~ ~s(<textarea)

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Edited Markdown Note",
        "description" => "",
        "creator" => "Edited Creator",
        "content" => "## Edited content"
      }
    })

    assert %Note{
             title: "Edited Markdown Note",
             creator: "Edited Creator",
             content: "## Edited content"
           } =
             GaoNote.get_note!(note.id)

    assert_patch(view, ~p"/gao_notes/notes/#{note.id}")
  end

  test "admin show renders note content with the markdown component", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Markdown Show Note",
                 content: "## Rendered markdown"
               },
               user
             )

    {:ok, _view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}")

    assert html =~ ~s(<el-dm-markdown)
    assert html =~ ~s(id="gao-note-content-#{note.id}")
    assert html =~ "## Rendered markdown"
    refute html =~ "react"
    refute html =~ "Failed to render_to_static_markup"
  end

  test "admin deletes a note from the list action column", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "List Delete Note",
                 content: "Delete from list"
               },
               user
             )

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
    html = render_async(view)

    assert html =~ note.title
    assert html =~ ~s(id="gao-note-list-delete-#{note.id}")
    assert html =~ ~s(id="confirm-dialog-gao-note-list-delete-#{note.id}")
    refute html =~ ~s(data-confirm="Delete this GaoNote?")

    assert has_element?(
             view,
             "#gao-note-delete-list-cancel-#{note.id} button[type='button'][onclick]",
             "Cancel"
           )

    view
    |> element(~s(#gao-note-delete-list-confirm-#{note.id} [phx-click="delete"]))
    |> render_click()

    assert [] = GaoNote.list_notes(search: "List Delete Note")
    assert_patch(view, ~p"/gao_notes/notes")
  end

  test "admin deletes a note from a modal confirmation", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Delete Modal Note",
                 content: "Delete me"
               },
               user
             )

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}")

    assert html =~ ~s(id="gao-note-delete-#{note.id}")
    assert html =~ ~s(id="confirm-dialog-gao-note-delete-#{note.id}")
    assert html =~ "Delete GaoNote"
    refute html =~ ~s(data-confirm="Delete this GaoNote?")

    assert has_element?(
             view,
             "#gao-note-delete-cancel-#{note.id} button[type='button'][onclick]",
             "Cancel"
           )

    view
    |> element(~s([phx-click="delete"][phx-value-id="#{note.id}"]))
    |> render_click()

    assert [] = GaoNote.list_notes(search: "Delete Modal Note")
    assert_patch(view, ~p"/gao_notes/notes")
  end

  test "admin can manage tags", %{conn: conn} do
    assert {:ok, _tag} = GaoNote.create_tag(%{name: "Existing Managed Tag"})

    {:ok, view, html} = live(conn, ~p"/gao_notes/tags")

    assert html =~ "GaoNote Tags"
    assert html =~ ~s(id="gao-note-tags-loading")
    assert html =~ ~s(aria-label="Loading GaoNote tags")
    refute html =~ "Loading tags"

    html = render_async(view)

    assert html =~ "Existing Managed Tag"
    assert html =~ ~s(id="gao-note-tags-table")
    refute html =~ "Save"
    refute html =~ ~s(id="gao-note-tags-loading")

    view
    |> form("#gao-note-tag-form", %{
      "gao_note_tag" => %{"name" => "Research", "color" => "#1f6feb"}
    })
    |> render_submit()

    assert [%Tag{name: "Existing Managed Tag"}, %Tag{name: "Research", slug: "research"} = tag] =
             GaoNote.list_tags()

    assert render_async(view) =~ "Research"

    view
    |> element(~s([phx-click="delete"][phx-value-id="#{tag.id}"]))
    |> render_click()

    assert [%Tag{name: "Existing Managed Tag"}] = GaoNote.list_tags()
  end

  test "admin can view GaoNote CRUD logs", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Logged LiveView Note", content: "Logged content"},
               user
             )

    assert {:ok, note} =
             GaoNote.update_note(
               note,
               %{title: "Logged LiveView Note Updated", content: "Updated content"},
               user
             )

    assert {:ok, _deleted} = GaoNote.delete_note(note, user)

    {:ok, view, html} = live(conn, ~p"/gao_notes/logs")

    assert html =~ "GaoNote Log"
    assert html =~ ~s(id="gao-note-log-loading")
    assert html =~ ~s(aria-label="Loading GaoNote log")

    html = render_async(view)

    assert html =~ "Logged LiveView Note Updated"
    assert html =~ "create"
    assert html =~ "update"
    assert html =~ "delete"
    assert html =~ user.id
    refute html =~ ~s(id="gao-note-log-loading")
  end

  test "admin can open the global note references menu page", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Reference Menu Note", content: "Reference menu content"},
               user
             )

    assert {:ok, reference} =
             GaoNote.add_reference(
               note,
               %{url: "https://example.com/menu-reference", title: "Menu Reference"},
               user
             )

    {:ok, _view, html} = live(conn, ~p"/gao_notes/references")

    assert html =~ "GaoNote References"
    assert html =~ ~s(id="gao-note-references-table")
    assert html =~ "Reference Menu Note"
    assert html =~ "Menu Reference"
    assert html =~ reference.url
    assert html =~ ~s(href="/gao_notes/notes/#{note.id}/references")
  end

  test "admin can open the global note assets menu page", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Asset Menu Note", content: "Asset menu content"},
               user
             )

    storage_file = storage_file_fixture(%{filename: "asset-menu.txt"})

    assert {:ok, _asset} =
             GaoNote.attach_asset(
               note,
               storage_file.id,
               %{role: "cover", caption: "Menu Caption"},
               user
             )

    {:ok, _view, html} = live(conn, ~p"/gao_notes/assets")

    assert html =~ "GaoNote Assets"
    assert html =~ ~s(id="gao-note-assets-table")
    assert html =~ "Asset Menu Note"
    assert html =~ "asset-menu.txt"
    assert html =~ "cover"
    assert html =~ "Menu Caption"
    assert html =~ ~s(href="/gao_notes/notes/#{note.id}/assets")
  end

  test "admin can configure and test GaoNote MCP", %{conn: conn, user: user} do
    assert {:ok, _note} =
             GaoNote.create_note(
               %{title: "MCP Console Note", content: "Console content"},
               user
             )

    {:ok, view, html} = live(conn, ~p"/gao_notes/mcp")

    assert html =~ "GaoNote MCP"
    assert html =~ ~s(id="gao-note-mcp-loading")

    html = render_async(view)

    assert html =~ "gsmlg-gao-note-admin"
    assert html =~ "/mcp/gao_note"
    assert html =~ "gao_note.search"
    assert html =~ "gao_note.create"
    assert html =~ "gaonote://notes/{id}"
    assert html =~ ~s(id="gao-note-mcp-api-key-form")
    assert html =~ ~s(id="gao-note-mcp-test-form")

    html = render_click(view, "generate_api_key")

    assert html =~ ~s(id="gao-note-mcp-generated-key")
    assert %MCPSetting{actor_id: actor_id} = GaoNote.get_mcp_setting()
    assert actor_id == user.id

    html =
      render_submit(view, "run_tool", %{
        "mcp_test" => %{
          "tool" => "gao_note.search",
          "arguments" => ~s({"query": "MCP Console", "limit": 10})
        }
      })

    assert html =~ ~s(id="gao-note-mcp-test-result")
    assert html =~ "MCP Console Note"
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end

  defp storage_file_fixture(attrs) do
    defaults = %{
      tenant: "gao_note",
      type: "asset",
      filename: "note.txt",
      s3_key: "gao_note/asset/#{Ecto.UUID.generate()}.txt",
      content_type: "text/plain",
      size: 64,
      checksum: Ecto.UUID.generate(),
      metadata: %{},
      variants: %{},
      status: "active",
      uploaded_by: "admin-test"
    }

    %StorageFile{}
    |> StorageFile.changeset(Map.merge(defaults, attrs))
    |> Repo.insert!()
  end
end
