defmodule GSMLG.AdminWeb.GaoNoteLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  defmodule S3Stub do
    @behaviour Plug

    @impl true
    def init(opts), do: opts

    @impl true
    def call(conn, _opts) do
      conn
      |> drain_body()
      |> Plug.Conn.put_resp_header("etag", "\"test-etag\"")
      |> Plug.Conn.send_resp(200, "")
    end

    defp drain_body(conn) do
      case Plug.Conn.read_body(conn) do
        {:ok, _body, conn} -> conn
        {:more, _body, conn} -> drain_body(conn)
      end
    end
  end

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
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
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
                 labels: ["Admin Label", "MCP Label"]
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
    assert html =~ "Admin Label"
    assert html =~ "MCP Label"
    assert html =~ ~s(href="/gao_notes/notes/#{note.id}/attachments")
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/references")
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/assets")
    refute html =~ ~s(id="gao-note-table-loading")
    refute html =~ "Description"
    refute html =~ "Admin description"
  end

  test "admin can create a note", %{conn: conn} do
    assert {:ok, _label_setting} = GaoNote.create_label_setting(%{name: "Existing Label"})

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/new")

    refute html =~ "Slug"
    refute html =~ "Status"
    refute html =~ "Visibility"
    assert html =~ "Labels"
    assert html =~ "Loading labels"

    html = render_async(view)

    assert html =~ "Existing Label"
    assert html =~ "<el-dm-markdown-input"
    assert html =~ ~s(name="gao_note[content]")
    refute html =~ ~s(<textarea)
    assert html =~ ~s(id="gao-note-labels")
    assert html =~ ~s(<button type="submit")
    refute html =~ ~s(<el-dm-button variant="primary" class="" style="" type="submit")

    render_change(view, "label_input_changed", %{"label_input" => "New Live Label"})

    assert render_click(view, "add_label_option", %{"name" => "New Live Label"}) =~
             "New Live Label"

    assert render_click(view, "set_labels", %{
             "labels" => ["Existing Label", "New Live Label"]
           }) =~ "Existing Label"

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Created From LiveView",
        "description" => "",
        "content" => "Created content",
        "labels" => ["Existing Label", "New Live Label"]
      }
    })

    assert [
             %Note{
               title: "Created From LiveView",
               description: "",
               content: "Created content"
             } = note
           ] =
             GaoNote.list_notes(search: "Created From LiveView")

    assert Enum.map(note.labels, & &1.label_setting.name) |> Enum.sort() == [
             "Existing Label",
             "New Live Label"
           ]

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
        "content" => "## Edited content"
      }
    })

    assert %Note{
             title: "Edited Markdown Note",
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
    assert html =~ "Attachments"
    assert html =~ ~s(href="/gao_notes/notes/#{note.id}/attachments")
    refute html =~ "References"
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/references")
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/assets")
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

  test "admin can manage label settings", %{conn: conn} do
    assert {:ok, _label_setting} =
             GaoNote.create_label_setting(%{name: "Existing Managed Label"})

    {:ok, view, html} = live(conn, ~p"/gao_notes/label_settings")

    assert html =~ "GaoNote Labels"
    assert html =~ ~s(id="gao-note-label_settings-loading")
    assert html =~ ~s(aria-label="Loading GaoNote labels")

    html = render_async(view)

    assert html =~ "Existing Managed Label"
    assert html =~ ~s(id="gao-note-label_settings-table")
    refute html =~ "Slug"
    refute html =~ ~s(id="gao-note-label_settings-loading")

    view
    |> form("#gao-note-label_setting-form", %{
      "gao_note_label_setting" => %{"name" => "Research", "color" => "#1f6feb"}
    })
    |> render_submit()

    assert [
             %LabelSetting{name: "Existing Managed Label"},
             %LabelSetting{name: "Research"} = label_setting
           ] = GaoNote.list_label_settings()

    assert render_async(view) =~ "Research"

    view
    |> element(~s([phx-click="delete"][phx-value-id="#{label_setting.id}"]))
    |> render_click()

    assert [%LabelSetting{name: "Existing Managed Label"}] = GaoNote.list_label_settings()
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

  test "attachment routes isolate note scope and ignore id query on the global action", %{
    conn: conn,
    user: user
  } do
    assert {:ok, first_note} =
             GaoNote.create_note(
               %{title: "First Attachment Note", content: "First attachment content"},
               user
             )

    assert {:ok, second_note} =
             GaoNote.create_note(
               %{title: "Second Attachment Note", content: "Second attachment content"},
               user
             )

    first_file = storage_file_fixture(%{filename: "first-route-attachment.txt"})
    second_file = storage_file_fixture(%{filename: "second-route-attachment.txt"})

    assert {:ok, first_attachment} =
             GaoNote.attach_existing_file(
               first_note.id,
               first_file.id,
               %{
                 role: "cover",
                 path: "first-route-attachment.txt",
                 caption: "First Route Caption",
                 metadata: %{"visibility" => "public"}
               },
               actor: user
             )

    assert {:ok, second_attachment} =
             GaoNote.attach_existing_file(
               second_note.id,
               second_file.id,
               %{
                 role: "attachment",
                 path: "second-route-attachment.txt",
                 caption: "Second Route Caption",
                 metadata: %{"visibility" => "private"}
               },
               actor: user
             )

    assert {:ok, _view, note_html} =
             live(conn, ~p"/gao_notes/notes/#{first_note.id}/attachments")

    assert note_html =~ "First Attachment Note Attachments"
    assert note_html =~ "first-route-attachment.txt"
    assert note_html =~ "First Route Caption"
    assert note_html =~ ~s(id="gao-note-attachment-#{first_attachment.id}")
    refute note_html =~ "second-route-attachment.txt"
    refute note_html =~ "Second Route Caption"
    refute note_html =~ ~s(id="gao-note-attachment-#{second_attachment.id}")

    assert {:ok, _view, scoped_query_html} =
             live(conn, "/gao_notes/notes/#{first_note.id}/attachments?page=2")

    assert scoped_query_html =~ "first-route-attachment.txt"
    refute scoped_query_html =~ "second-route-attachment.txt"

    {:ok, _view, html} = live(conn, ~p"/gao_notes/attachments")

    assert html =~ "GaoNote Attachments"
    assert html =~ ~s(id="gao-note-attachments-table")
    assert html =~ "First Attachment Note"
    assert html =~ "Second Attachment Note"
    assert html =~ "first-route-attachment.txt"
    assert html =~ "second-route-attachment.txt"
    assert html =~ "First Route Caption"
    assert html =~ "Second Route Caption"
    assert html =~ "public"
    assert html =~ "private"
    assert html =~ ~s(href="/gao_notes/notes/#{first_note.id}/attachments")
    assert html =~ ~s(href="/gao_notes/notes/#{second_note.id}/attachments")
    refute html =~ ~s(href="/gao_notes/references")
    refute html =~ ~s(href="/gao_notes/assets")

    assert {:ok, _view, query_html} =
             live(conn, "/gao_notes/attachments?id=#{first_note.id}")

    assert query_html =~ "GaoNote Attachments"
    assert query_html =~ "First Attachment Note"
    assert query_html =~ "Second Attachment Note"
    assert query_html =~ "first-route-attachment.txt"
    assert query_html =~ "second-route-attachment.txt"
    assert query_html =~ "First Route Caption"
    assert query_html =~ "Second Route Caption"
    assert query_html =~ ~s(id="gao-note-attachments-table")
    assert query_html =~ ~s(href="/gao_notes/notes/#{first_note.id}/attachments")
    assert query_html =~ ~s(href="/gao_notes/notes/#{second_note.id}/attachments")
    refute query_html =~ ~s(id="gao-note-note-attachments")
    refute query_html =~ ~s(id="gao-note-attachment-upload-form")
  end

  test "global attachments paginate without omissions and support previous navigation", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Paginated Attachments", content: "Pagination content"},
               user
             )

    attachments =
      for index <- 1..26 do
        filename = "paginated-#{String.pad_leading(Integer.to_string(index), 2, "0")}.txt"
        file = storage_file_fixture(%{filename: filename})

        assert {:ok, %Attachment{} = attachment} =
                 GaoNote.attach_existing_file(
                   note.id,
                   file.id,
                   %{caption: "Caption #{index}", metadata: %{"visibility" => "public"}},
                   actor: user
                 )

        {filename, attachment.id}
      end

    tied_inserted_at = ~U[2026-07-16 00:00:00.000000Z]
    assert {26, nil} = Repo.update_all(Attachment, set: [inserted_at: tied_inserted_at])

    expected_filenames =
      attachments
      |> Enum.sort_by(fn {_filename, id} -> id end, :desc)
      |> Enum.map(fn {filename, _id} -> filename end)

    {expected_first_page, expected_second_page} = Enum.split(expected_filenames, 25)

    {:ok, view, first_page_html} = live(conn, ~p"/gao_notes/attachments")

    assert first_page_html =~ ~s(id="gao-note-attachments-table")
    assert first_page_html =~ ~s(id="gao-note-attachments-next")
    refute first_page_html =~ ~s(id="gao-note-attachments-previous")

    for filename <- expected_first_page, do: assert(first_page_html =~ filename)
    for filename <- expected_second_page, do: refute(first_page_html =~ filename)

    view
    |> element("#gao-note-attachments-next")
    |> render_click()

    assert_patch(view, "/gao_notes/attachments?page=2")
    second_page_html = render(view)
    assert second_page_html =~ ~s(id="gao-note-attachments-previous")
    refute second_page_html =~ ~s(id="gao-note-attachments-next")

    for filename <- expected_first_page, do: refute(second_page_html =~ filename)
    for filename <- expected_second_page, do: assert(second_page_html =~ filename)

    for filename <- expected_filenames do
      assert Enum.count([first_page_html, second_page_html], &String.contains?(&1, filename)) == 1
    end

    view
    |> element("#gao-note-attachments-previous")
    |> render_click()

    assert_patch(view, "/gao_notes/attachments?page=1")
  end

  test "forged mutations on the global attachment page are stable no-ops", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Global Mutation Guard", content: "Mutation guard content"},
               user
             )

    file = storage_file_fixture(%{filename: "guarded.txt"})
    second_file = storage_file_fixture(%{filename: "must-not-attach.txt"})

    assert {:ok, attachment} =
             GaoNote.attach_existing_file(
               note.id,
               file.id,
               %{caption: "Original caption", metadata: %{"visibility" => "private"}},
               actor: user
             )

    {:ok, view, _html} = live(conn, ~p"/gao_notes/attachments")

    forged_events = [
      {"upload", %{"attachment" => %{"visibility" => "public"}}},
      {"attach",
       %{
         "attachment" => %{
           "storage_file_id" => second_file.id,
           "caption" => "Must not attach",
           "visibility" => "public"
         }
       }},
      {"update",
       %{
         "id" => attachment.id,
         "attachment" => %{"caption" => "Forged caption", "visibility" => "public"}
       }},
      {"detach", %{"id" => attachment.id}}
    ]

    for {event, params} <- forged_events do
      assert render_hook(view, event, params) =~
               "Attachment changes require a note-scoped page"
    end

    assert [%Attachment{id: id, caption: "Original caption"}] =
             GaoNote.list_attachments(note.id)

    assert id == attachment.id
    refute Enum.any?(GaoNote.list_attachments(note.id), &(&1.storage_file_id == second_file.id))
  end

  test "admin can attach, update, and detach an existing file", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Manage Attachments", content: "Attachment management"},
               user
             )

    storage_file = storage_file_fixture(%{filename: "existing-file.txt"})
    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}/attachments")

    assert html =~ ~s(id="gao-note-attachment-upload-form")
    assert html =~ ~s(id="gao-note-attachment-attach-form")
    assert html =~ "Private"
    assert html =~ "Public"

    view
    |> form("#gao-note-attachment-attach-form", %{
      "attachment" => %{
        "storage_file_id" => storage_file.id,
        "role" => "inline",
        "path" => "existing-file.txt",
        "description" => "Existing description",
        "caption" => "Existing caption",
        "alt_text" => "Existing alt text",
        "position" => "2",
        "visibility" => "private",
        "unknown_attachment_field" => "must be ignored"
      }
    })
    |> render_submit()

    assert [
             %Attachment{
               role: "inline",
               path: "./existing-file.txt",
               description: "Existing description",
               caption: "Existing caption",
               alt_text: "Existing alt text",
               position: 2,
               metadata: %{"visibility" => "private"}
             } = attachment
           ] = GaoNote.list_attachments(note.id)

    assert has_element?(
             view,
             "#gao-note-attachment-detach-#{attachment.id}[data-confirm='Detach this attachment?']"
           )

    view
    |> form("#gao-note-attachment-update-#{attachment.id}", %{
      "attachment" => %{
        "role" => "cover",
        "path" => "updated-file.txt",
        "description" => "Updated description",
        "caption" => "Updated caption",
        "alt_text" => "Updated alt text",
        "position" => "4",
        "visibility" => "public"
      }
    })
    |> render_submit()

    assert %Attachment{
             role: "cover",
             path: "./updated-file.txt",
             description: "Updated description",
             caption: "Updated caption",
             alt_text: "Updated alt text",
             position: 4,
             metadata: %{"visibility" => "public"}
           } = GaoNote.get_attachment(attachment.id)

    view
    |> element("#gao-note-attachment-detach-#{attachment.id}")
    |> render_click()

    assert GaoNote.list_attachments(note.id) == []
    assert %StorageFile{status: "active"} = Repo.get(StorageFile, storage_file.id)
  end

  test "admin upload keeps the client filename and defaults a note-relative path", %{
    conn: conn,
    user: user
  } do
    with_storage_test_config(fn ->
      assert {:ok, note} =
               GaoNote.create_note(
                 %{title: "Upload Attachment", content: "Upload attachment content"},
                 user
               )

      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/attachments")
      filename = "client-report-#{System.unique_integer([:positive])}.txt"
      contents = "attachment uploaded from LiveView"

      upload =
        file_input(view, "#gao-note-attachment-upload-form", :attachment, [
          %{name: filename, content: contents, type: "text/plain"}
        ])

      render_upload(upload, filename)

      view
      |> form("#gao-note-attachment-upload-form", %{
        "attachment" => %{
          "role" => "attachment",
          "path" => "",
          "description" => "Uploaded description",
          "caption" => "Uploaded caption",
          "alt_text" => "Uploaded alt text",
          "position" => "0",
          "visibility" => "private"
        }
      })
      |> render_submit()

      assert [
               %Attachment{
                 path: expected_path,
                 metadata: %{"visibility" => "private"},
                 storage_file:
                   %StorageFile{
                     filename: stored_filename,
                     content_type: "text/plain",
                     type: "attachment"
                   } = stored_file
               } = attachment
             ] = GaoNote.list_attachments(note.id)

      assert stored_filename == filename
      assert expected_path == "./#{filename}"
      refute expected_path =~ "temporary"
      refute render(view) =~ stored_file.s3_key

      assert {:ok, _attachment} = GaoNote.detach_attachment(note.id, attachment.id)
    end)
  end

  test "recycle bin remains wrapped in the admin layout", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: "Recycle Layout Note", content: "Recycle layout content"},
               user
             )

    assert {:ok, _deleted_note} = GaoNote.delete_note(note, user)
    assert {:ok, _view, html} = live(conn, ~p"/gao_notes/recycle_bin")

    assert html =~ "Recycle Bin"
    assert html =~ ~s(aria-label="Admin navigation")
  end

  test "recycle bin restore and purge actions audit the current admin", %{conn: conn, user: user} do
    assert {:ok, restore_note} =
             GaoNote.create_note(
               %{title: "Recycle Restore Actor", content: "Restore actor content"},
               user
             )

    assert {:ok, purge_note} =
             GaoNote.create_note(
               %{title: "Recycle Purge Actor", content: "Purge actor content"},
               user
             )

    assert {:ok, _deleted} = GaoNote.delete_note(restore_note, user)
    assert {:ok, _deleted} = GaoNote.delete_note(purge_note, user)

    {:ok, view, _html} = live(conn, ~p"/gao_notes/recycle_bin")
    render_async(view)

    view
    |> element("#deleted-note-#{restore_note.id} [phx-click=restore]")
    |> render_click()

    render_async(view)

    view
    |> element("#deleted-note-#{purge_note.id} [phx-click=purge]")
    |> render_click()

    restore_logs = GaoNote.list_logs(entity_type: "note", note_id: restore_note.id)
    purge_logs = GaoNote.list_logs(entity_type: "note", note_id: purge_note.id)

    assert Enum.any?(
             restore_logs,
             &match?(%Log{action: "restore", actor_id: actor_id} when actor_id == user.id, &1)
           )

    assert Enum.any?(
             purge_logs,
             &match?(%Log{action: "purge", actor_id: actor_id} when actor_id == user.id, &1)
           )
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
      type: "attachment",
      filename: "note.txt",
      s3_key: "gao_note/attachment/#{Ecto.UUID.generate()}.txt",
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

  defp with_storage_test_config(fun) do
    keys = [:allowed_types, :s3_bucket, :s3_endpoint]
    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :allowed_types, %{
      "attachment" => ["application/octet-stream", "text/plain"]
    })

    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    try do
      fun.()
    after
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      GenServer.stop(s3_stub)
    end
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
