defmodule GSMLG.AdminWeb.GaoNoteLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    Plug.Router.put "/*path" do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      notify({:s3_put, conn.request_path, body})
      send_resp(conn, 200, "")
    end

    Plug.Router.get "/*path" do
      notify({:s3_get, conn.request_path})
      send_resp(conn, 206, Application.get_env(:gsmlg_storage, :gao_note_live_test_object, ""))
    end

    Plug.Router.delete "/*path" do
      notify({:s3_delete, conn.request_path})
      send_resp(conn, 204, "")
    end

    Plug.Router.match(_, do: send_resp(conn, 200, ""))

    defp notify(message) do
      if pid = Application.get_env(:gsmlg_storage, :gao_note_live_test_pid) do
        send(pid, message)
      end
    end
  end

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @secret_key_base String.duplicate("a", 64)
  @storage_keys [
    :allowed_types,
    :gao_note_live_test_object,
    :gao_note_live_test_pid,
    :s3_access_key_id,
    :s3_bucket,
    :s3_endpoint,
    :s3_secret_access_key
  ]

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

    original_storage =
      Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})

    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => :any})
    Application.put_env(:gsmlg_storage, :gao_note_live_test_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_live_test_pid, self())
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    on_exit(fn ->
      Enum.each(original_storage, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      if Process.alive?(s3_stub) do
        try do
          GenServer.stop(s3_stub)
        catch
          :exit, _reason -> :ok
        end
      end
    end)

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
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/attachments")
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/references")
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/assets")
    refute html =~ ~s(id="gao-note-table-loading")
  end

  describe "Notes batch actions" do
    @describetag :gao_note_batch_actions

    test "notes table selection moves from none to mixed to all and clears", %{
      conn: conn,
      user: user
    } do
      first = note_fixture(user, "Select First")
      second = note_fixture(user, "Select Second")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)

      assert has_element?(view, "#gao-note-select-all[data-state='none']")
      refute has_element?(view, "#gao-note-batch-toolbar")

      render_click(view, "toggle_batch_note", %{"id" => first.id})
      assert has_element?(view, "#gao-note-select-all[data-state='mixed'][aria-checked='mixed']")
      assert has_element?(view, "#gao-note-batch-toolbar", "1 selected")

      render_click(view, "toggle_all_batch_notes")
      assert has_element?(view, "#gao-note-select-all[data-state='all']")
      assert has_element?(view, "#gao-note-select-#{first.id}[checked]")
      assert has_element?(view, "#gao-note-select-#{second.id}[checked]")
      assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")

      render_click(view, "clear_batch_selection")
      assert has_element?(view, "#gao-note-select-all[data-state='none']")
      refute has_element?(view, "#gao-note-batch-toolbar")
    end

    test "filter changes clear selection and reload reconciliation removes stale selected ids", %{
      conn: conn,
      user: user
    } do
      selected = note_fixture(user, "Selected Filter Note")
      _other = note_fixture(user, "Other Filter Note")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)

      render_click(view, "toggle_batch_note", %{"id" => selected.id})

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => "Other"}})
      |> render_submit()

      assert_patch(view, ~p"/gao_notes/notes?search=Other")
      render_async(view)
      refute has_element?(view, "#gao-note-batch-toolbar")

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => ""}})
      |> render_submit()

      assert_patch(view, ~p"/gao_notes/notes")
      render_async(view)
      render_click(view, "toggle_batch_note", %{"id" => selected.id})

      view
      |> element(~s(#gao-note-delete-list-confirm-#{selected.id} [phx-click="delete"]))
      |> render_click()

      render_async(view)
      refute has_element?(view, "#gao-note-batch-toolbar")
      refute has_element?(view, "#gao-note-row-#{selected.id}")
    end

    test "unsubmitted filter form changes clear batch selection immediately", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, "Draft Filter Selection")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [note])
      assert has_element?(view, "#gao-note-batch-toolbar", "1 selected")

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => "not submitted"}})
      |> render_change()

      refute has_element?(view, "#gao-note-batch-toolbar")
      assert has_element?(view, "#gao-note-row-#{note.id}")
    end

    test "unsubmitted typing does not invalidate the active URL async load", %{
      conn: conn,
      user: user
    } do
      setting = label_setting_fixture("Async Catalog Label")
      note = note_fixture(user, "Active URL Result")
      {:ok, view, html} = live(conn, ~p"/gao_notes/notes")
      assert html =~ ~s(id="gao-note-table-loading")

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => "unsubmitted miss"}})
      |> render_change()

      assert %{active_filters: %{"search" => "", "labels" => []}} =
               :sys.get_state(view.pid).socket.assigns

      html = render_async(view)
      assert html =~ note.title
      refute html =~ ~s(id="gao-note-table-loading")

      render_click(view, "toggle_batch_note", %{"id" => note.id})
      render_click(view, "open_batch_label_modal")
      assert has_element?(view, ~s(option[value="#{setting.id}"]), setting.name)
    end

    test "submitting draft filters updates the active URL and loaded result", %{
      conn: conn,
      user: user
    } do
      selected = note_fixture(user, "Submitted Filter Match")
      hidden = note_fixture(user, "Submitted Filter Hidden")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [hidden])

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => "Match"}})
      |> render_change()

      refute has_element?(view, "#gao-note-batch-toolbar")

      view
      |> form("#gao-note-filter-form", %{"filters" => %{"search" => "Match"}})
      |> render_submit()

      assert_patch(view, ~p"/gao_notes/notes?search=Match")
      html = render_async(view)
      assert html =~ selected.title
      refute html =~ hidden.title
      refute has_element?(view, "#gao-note-batch-toolbar")
    end

    test "native notes table exposes semantic headers, stable rows, and existing row actions", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, "Native Table Note", ["project=umbrella"])
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)

      assert has_element?(view, "table#gao-note-table")
      assert has_element?(view, "#gao-note-select-all[aria-label='Select all loaded notes']")
      assert has_element?(view, "#gao-note-row-#{note.id}")

      assert has_element?(
               view,
               "#gao-note-select-#{note.id}[aria-label='Select Native Table Note']"
             )

      for heading <- ["Title", "Labels", "Created", "Updated", "Actions"] do
        assert has_element?(view, "#gao-note-table thead th", heading)
      end

      assert has_element?(view, ~s(a[href="/gao_notes/notes/#{note.id}/show"]), note.title)
      assert has_element?(view, ~s(a[href="/gao_notes/notes/#{note.id}/edit"]))
      assert has_element?(view, "#gao-note-list-delete-#{note.id}")
    end

    test "batch label modal switches catalog-only Add Edit and Delete fields", %{
      conn: conn,
      user: user
    } do
      setting = label_setting_fixture("Catalog Project")
      note = note_fixture(user, "Conditional Batch Form")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [note])
      render_click(view, "open_batch_label_modal")

      assert has_element?(view, ~s(option[value="#{setting.id}"]), setting.name)
      assert has_element?(view, ~s(select[name="batch_label[target_label_setting_id]"]))
      refute has_element?(view, ~s(select[name="batch_label[match_label_setting_id]"]))
      refute has_element?(view, ~s(input[name="batch_label[label_key]"]))

      change_batch_label(view, %{"action" => "edit"})
      assert has_element?(view, ~s(select[name="batch_label[match_label_setting_id]"]))
      assert has_element?(view, ~s(select[name="batch_label[target_label_setting_id]"]))

      change_batch_label(view, %{"action" => "delete"})
      assert has_element?(view, ~s(select[name="batch_label[match_label_setting_id]"]))
      refute has_element?(view, ~s(select[name="batch_label[target_label_setting_id]"]))
    end

    test "batch Add changes missing labels, preserves exact labels, audits, and clears selection",
         %{
           conn: conn,
           user: user
         } do
      project = label_setting_fixture("project")
      missing = note_fixture(user, "Batch Add Missing")
      exact = note_fixture(user, "Batch Add Exact", ["project=alpha"])
      Repo.delete_all(Log)

      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [missing, exact])
      render_click(view, "open_batch_label_modal")

      params = %{
        "action" => "add",
        "target_label_setting_id" => project.id,
        "target_value" => " alpha "
      }

      html = change_batch_label(view, params)
      assert html =~ "2 selected"
      assert html =~ "1"
      refute has_element?(view, "#gao-note-batch-label-submit[disabled]")

      submit_batch_label(view, params)
      render_async(view)

      assert %{"project" => "alpha"} = labels_for_note(missing.id)
      assert %{"project" => "alpha"} = labels_for_note(exact.id)
      assert [%Log{action: "update", entity_id: changed_id}] = GaoNote.list_logs()
      assert changed_id == missing.id
      assert render(view) =~ "1 changed, 1 unchanged"
      refute has_element?(view, "#gao-note-batch-toolbar")
    end

    test "batch Add conflict disables submit and retains the modal selection without changes", %{
      conn: conn,
      user: user
    } do
      project = label_setting_fixture("project")
      missing = note_fixture(user, "Conflict Would Change")
      conflict = note_fixture(user, "Conflict Existing", ["project=beta"])
      Repo.delete_all(Log)

      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [missing, conflict])
      render_click(view, "open_batch_label_modal")

      params = %{
        "action" => "add",
        "target_label_setting_id" => project.id,
        "target_value" => "alpha"
      }

      html = change_batch_label(view, params)
      assert html =~ "Conflict"
      assert has_element?(view, "#gao-note-batch-label-submit[disabled]")

      html = render_submit(view, "submit_batch_label", %{"batch_label" => params})
      assert html =~ "conflict"
      assert has_element?(view, "#gao-note-batch-label-modal")
      assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")
      assert labels_for_note(missing.id) == %{}
      assert %{"project" => "beta"} = labels_for_note(conflict.id)
      assert GaoNote.list_logs() == []
    end

    test "exact Edit and any Delete affect only matching labels and preserve unrelated labels", %{
      conn: conn,
      user: user
    } do
      status = label_setting_fixture("status")
      type = label_setting_fixture("type")
      draft = note_fixture(user, "Exact Draft", ["status=draft", "project=umbrella"])
      published = note_fixture(user, "Exact Published", ["status=published", "project=umbrella"])

      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [draft, published])
      render_click(view, "open_batch_label_modal")

      edit_params = %{
        "action" => "edit",
        "match_label_setting_id" => status.id,
        "match_value" => " draft ",
        "target_label_setting_id" => type.id,
        "target_value" => "article"
      }

      change_batch_label(view, edit_params)
      submit_batch_label(view, edit_params)
      render_async(view)

      assert %{"project" => "umbrella", "type" => "article"} = labels_for_note(draft.id)
      assert %{"project" => "umbrella", "status" => "published"} = labels_for_note(published.id)

      select_notes(view, [published])
      render_click(view, "open_batch_label_modal")

      delete_params = %{
        "action" => "delete",
        "match_label_setting_id" => status.id,
        "match_value" => ""
      }

      change_batch_label(view, delete_params)
      submit_batch_label(view, delete_params)
      render_async(view)
      assert %{"project" => "umbrella"} = labels_for_note(published.id)
    end

    test "exact Delete removes only the matching value", %{conn: conn, user: user} do
      status = label_setting_fixture("status")
      draft = note_fixture(user, "Exact Delete Draft", ["status=draft", "project=umbrella"])

      published =
        note_fixture(user, "Exact Delete Published", ["status=published", "project=umbrella"])

      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [draft, published])
      render_click(view, "open_batch_label_modal")

      params = %{
        "action" => "delete",
        "match_label_setting_id" => status.id,
        "match_value" => " draft "
      }

      change_batch_label(view, params)
      submit_batch_label(view, params)
      render_async(view)

      assert %{"project" => "umbrella"} = labels_for_note(draft.id)
      assert %{"project" => "umbrella", "status" => "published"} =
               labels_for_note(published.id)
    end

    test "zero-match label operation is an informational unaudited no-op", %{
      conn: conn,
      user: user
    } do
      status = label_setting_fixture("status")
      note = note_fixture(user, "Zero Match", ["project=umbrella"])
      Repo.delete_all(Log)
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [note])
      render_click(view, "open_batch_label_modal")

      params = %{
        "action" => "delete",
        "match_label_setting_id" => status.id,
        "match_value" => ""
      }

      change_batch_label(view, params)
      submit_batch_label(view, params)
      render_async(view)
      assert render(view) =~ "No matching labels"
      assert %{"project" => "umbrella"} = labels_for_note(note.id)
      assert GaoNote.list_logs() == []
    end

    test "invalid typed label value retains the modal and selection with validation text", %{
      conn: conn,
      user: user
    } do
      year = label_setting_fixture("year", "year")
      note = note_fixture(user, "Invalid Typed Label")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [note])
      render_click(view, "open_batch_label_modal")

      html =
        change_batch_label(view, %{
          "action" => "add",
          "target_label_setting_id" => year.id,
          "target_value" => "twenty twenty-six"
        })

      assert html =~ "must be YYYY"
      assert has_element?(view, "#gao-note-batch-label-submit[disabled]")
      assert has_element?(view, "#gao-note-batch-label-modal")
      assert has_element?(view, "#gao-note-batch-toolbar", "1 selected")
      assert labels_for_note(note.id) == %{}
    end

    test "stale selected note label error retains modal and atomic selection", %{
      conn: conn,
      user: user
    } do
      project = label_setting_fixture("project")
      active = note_fixture(user, "Stale Label Active")
      stale = note_fixture(user, "Stale Label Deleted")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [active, stale])
      render_click(view, "open_batch_label_modal")
      assert {:ok, _deleted} = GaoNote.delete_note(stale, user)

      params = %{
        "action" => "add",
        "target_label_setting_id" => project.id,
        "target_value" => "umbrella"
      }

      change_batch_label(view, params)
      html = submit_batch_label(view, params)
      assert html =~ "changed or disappeared"
      assert has_element?(view, "#gao-note-batch-label-modal")
      assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")
      assert labels_for_note(active.id) == %{}
    end

    test "batch soft delete moves two notes atomically and clears selection", %{
      conn: conn,
      user: user
    } do
      first = note_fixture(user, "Batch Recycle First")
      second = note_fixture(user, "Batch Recycle Second")
      Repo.delete_all(Log)
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [first, second])
      render_click(view, "open_batch_delete_modal")

      render_click(view, "batch_delete_notes")
      render_async(view)

      assert GaoNote.get_note(first.id) == nil
      assert GaoNote.get_note(second.id) == nil
      assert %Note{deleted_at: %DateTime{}} = GaoNote.get_deleted_note(first.id)
      assert %Note{deleted_at: %DateTime{}} = GaoNote.get_deleted_note(second.id)
      assert 2 == GaoNote.list_logs() |> Enum.filter(&(&1.action == "delete")) |> length()
      assert render(view) =~ "2 notes moved to the Recycle Bin"
      refute has_element?(view, "#gao-note-batch-toolbar")
    end

    test "stale batch soft delete rolls back active notes and retains modal selection", %{
      conn: conn,
      user: user
    } do
      active = note_fixture(user, "Stale Delete Active")
      stale = note_fixture(user, "Stale Delete Gone")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [active, stale])
      render_click(view, "open_batch_delete_modal")
      assert {:ok, _deleted} = GaoNote.delete_note(stale, user)

      html = render_click(view, "batch_delete_notes")
      assert html =~ "changed or disappeared"
      assert %Note{deleted_at: nil} = GaoNote.get_note(active.id)
      assert has_element?(view, "#gao-note-batch-delete-modal")
      assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")
    end

    test "connected notes page has no duplicate ids after async rendering", %{
      conn: conn,
      user: user
    } do
      note = note_fixture(user, "Unique IDs")
      {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
      render_async(view)
      select_notes(view, [note])
      render_click(view, "open_batch_label_modal")

      ids =
        view
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("[id]")
        |> Floki.attribute("id")

      duplicates = ids -- Enum.uniq(ids)
      assert duplicates == []
    end
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
    assert html =~ ~s(id="gao-note-attachments")
    assert html =~ "No attachments staged"
    assert html =~ "Add attachment"
    assert html =~ ~s(<button type="submit")
    refute html =~ ~s(<el-dm-button variant="primary" class="" style="" type="submit")

    render_change(view, "label_input_changed", %{
      "label_key_input" => "New Live Label",
      "label_value_input" => ""
    })

    assert render_click(view, "add_label_option", %{
             "key" => "New Live Label",
             "value" => ""
           }) =~
             "New Live Label"

    assert render_click(view, "set_labels", %{
             "labels" => ["Existing Label", "New Live Label"]
           }) =~ "Existing Label"

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Created From LiveView",
        "content" => "Created content",
        "labels" => ["Existing Label", "New Live Label"]
      }
    })

    assert [
             %Note{
               title: "Created From LiveView",
               content: "Created content",
               attachments: []
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
          "content" => ""
        }
      })

    assert html =~ "can&#39;t be blank"
    assert html =~ ~s(id="gao_note_title-errors")
    assert html =~ ~s(id="gao_note_content-errors")
  end

  test "attachment modal disables native dismissal and exposes only explicit actions", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)

    assert has_element?(view, "el-dm-dialog#gao-note-attachment-modal[no-dismiss]")
    refute has_element?(view, "el-dm-dialog#gao-note-attachment-modal [slot='close']")
    assert has_element?(view, "#gao-note-attachment-form [phx-click='cancel_attachment_modal']")
    assert has_element?(view, "#gao-note-attachment-form button[type='submit']")
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

  test "admin show renders note content as server-side safe HTML", %{conn: conn, user: user} do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Markdown Show Note",
                 content: "## Rendered markdown"
               },
               user
             )

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}")

    refute html =~ ~s(<el-dm-markdown)
    assert html =~ ~s(id="gao-note-content-#{note.id}")
    assert has_element?(view, "#gao-note-content-#{note.id} h2", "Rendered markdown")
    refute html =~ "Add attachment"
    refute html =~ ~s(href="/gao_notes/notes/#{note.id}/attachments")
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
    assert html =~ ~s(id="gao-note-label-setting-create-modal")
    assert html =~ ~s(id="gao-note-label-setting-create")
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
    |> form("#gao-note-label-setting-edit-form-#{label_setting.id}", %{
      "gao_note_label_setting" => %{
        "name" => "Research Updated",
        "color" => "#ff5500",
        "value_type" => "version",
        "description" => "Release stream"
      }
    })
    |> render_submit()

    assert [
             %LabelSetting{name: "Existing Managed Label"},
             %LabelSetting{
               id: label_setting_id,
               name: "Research Updated",
               color: "#ff5500",
               value_type: "version",
               description: "Release stream"
             }
           ] = GaoNote.list_label_settings()

    assert label_setting_id == label_setting.id

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
               %{
                 title: "Logged LiveView Note Updated",
                 content: "Updated content",
                 attachments: []
               },
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
    assert html =~ "gao_note.create_note"
    assert html =~ "gao_note.update_note"
    assert html =~ "gaonote://notes/{id}"
    assert html =~ "gaonote://label_settings/{id}"
    refute html =~ "gao_note.note.references"
    refute html =~ "gao_note.note.assets"
    refute html =~ "gao_note.asset"
    refute html =~ "gaonote://assets"
    refute html =~ "/references"
    assert html =~ ~s(id="gao-note-mcp-api-key-form")
    assert html =~ ~s(id="gao-note-mcp-test-form")

    html = render_click(view, "generate_api_key")

    assert html =~ ~s(id="gao-note-mcp-generated-key")
    assert %MCPSetting{actor_id: actor_id} = GaoNote.get_mcp_setting()
    assert actor_id == user.id

    html =
      render_change(view, "select_tool", %{
        "mcp_test" => %{"tool" => "gao_note.create_note", "arguments" => "{}"}
      })

    assert html =~ "attachments"
    refute html =~ "references"

    rejected_title = "Rejected Console Note #{System.unique_integer([:positive])}"

    html =
      render_submit(view, "run_tool", %{
        "mcp_test" => %{
          "tool" => "gao_note.create_note",
          "arguments" =>
            Jason.encode!(%{
              "title" => rejected_title,
              "content" => "body",
              "creator" => nil
            })
        }
      })

    assert html =~ "Invalid params"
    refute Repo.get_by(Note, title: rejected_title)

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

  test "create persists padded Base64 text and real Plug.Upload attachment payloads only on save", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)

    assert html =~ ~s(id="gao-note-attachments")
    assert html =~ "No attachments staged"

    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    html =
      render_submit(view, "stage_attachment", %{
        "attachment" => %{
          "id" => "readme",
          "path" => "docs//./readme.txt",
          "description" => "Read me",
          "source" => "text",
          "text" => "staged text"
        }
      })

    assert html =~ "readme"
    assert html =~ "./docs/readme.txt"
    assert html =~ "text/plain"
    assert html =~ "New"
    assert Repo.aggregate(Attachment, :count) == 0
    assert Repo.aggregate(StorageFile, :count) == 0
    refute_received {:s3_put, _path, _body}

    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "pixel.png", content: png, type: "text/plain"}
      ])

    render_upload(upload, "pixel.png")

    html =
      render_submit(view, "stage_attachment", %{
        "attachment" => %{
          "id" => "pixel",
          "path" => "./images/pixel.png",
          "description" => "Pixel",
          "source" => "file",
          "text" => ""
        }
      })

    assert html =~ "pixel"
    assert html =~ "./images/pixel.png"
    assert html =~ "image/png"
    assert Repo.aggregate(Attachment, :count) == 0
    assert Repo.aggregate(StorageFile, :count) == 0

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Attachment Draft Note",
        "content" => "Body",
        "labels" => []
      }
    })

    assert [%Note{} = note] = GaoNote.list_notes(search: "Attachment Draft Note")

    assert [
             %Attachment{id: "pixel", path: "./images/pixel.png", mime: "image/png"},
             %Attachment{
               id: "readme",
               path: "./docs/readme.txt",
               mime: "text/plain",
               description: "Read me"
             }
           ] = Enum.sort_by(note.attachments, & &1.id)

    assert_receive {:s3_put, _path, "staged text"}
    assert_receive {:s3_put, _path, ^png}
    assert_patch(view, ~p"/gao_notes/notes/#{note.id}")
  end

  test "edit keeps ID immutable and stages metadata, replacement, and removal", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Edit Attachments",
                 content: "Body",
                 attachments: [
                   text_attachment("keep-id", "./keep.txt", "old bytes", "Old"),
                   text_attachment("remove-id", "./remove.txt", "remove bytes", "")
                 ]
               },
               user
             )

    keep = attachment_by_id(note, "keep-id")
    remove = attachment_by_id(note, "remove-id")
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(view)

    view
    |> element(
      ~s([data-attachment-id="keep-id"] [phx-click="open_attachment_modal"][phx-value-operation="edit"])
    )
    |> render_click()

    assert has_element?(view, "#gao-note-attachment-form input[readonly][value='keep-id']")

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "tampered-id",
        "path" => "./docs/renamed.txt",
        "description" => "Updated metadata",
        "source" => "file",
        "text" => ""
      }
    })

    view
    |> element(
      ~s([data-attachment-id="keep-id"] [phx-click="open_attachment_modal"][phx-value-operation="replace"])
    )
    |> render_click()

    html =
      render_submit(view, "stage_attachment", %{
        "attachment" => %{
          "id" => "tampered-again",
          "path" => "./docs/renamed.txt",
          "description" => "Updated metadata",
          "source" => "text",
          "text" => "replacement bytes"
        }
      })

    assert html =~ "Replacement"
    assert html =~ "keep-id"
    assert html =~ "./docs/renamed.txt"
    refute html =~ "tampered-id"

    view
    |> element(~s([data-attachment-id="remove-id"] [phx-click="remove_attachment"]))
    |> render_click()

    assert %Attachment{storage_file_id: keep_storage_id} =
             reload_attachment(note.id, "keep-id")

    assert keep_storage_id == keep.storage_file_id

    assert %Attachment{storage_file_id: remove_storage_id} =
             reload_attachment(note.id, "remove-id")

    assert remove_storage_id == remove.storage_file_id
    refute_received {:s3_put, _path, _body}

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Edit Attachments",
        "content" => "Updated body",
        "labels" => []
      }
    })

    assert %Note{attachments: [%Attachment{} = updated]} = GaoNote.get_note(note.id)
    assert updated.id == "keep-id"
    assert updated.path == "./docs/renamed.txt"
    assert updated.description == "Updated metadata"
    assert updated.mime == "text/plain"
    refute updated.storage_file_id == keep.storage_file_id
    assert reload_attachment(note.id, "remove-id") == nil
    assert_receive {:s3_put, _path, "replacement bytes"}
  end

  test "modal and main cancel discard drafts while retained payloads have metadata only", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Cancel Attachment Drafts",
                 content: "Body",
                 attachments: [text_attachment("stable-id", "./stable.txt", "stable bytes", "")]
               },
               user
             )

    stable = attachment_by_id(note, "stable-id")
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(view)

    view
    |> element(
      ~s([data-attachment-id="stable-id"] [phx-click="open_attachment_modal"][phx-value-operation="replace"])
    )
    |> render_click()

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "replacement.txt", content: "not staged", type: "application/octet-stream"}
      ])

    render_upload(upload, "replacement.txt")
    render_click(view, "cancel_attachment_modal")

    assert %Attachment{storage_file_id: storage_file_id} =
             reload_attachment(note.id, "stable-id")

    assert storage_file_id == stable.storage_file_id
    refute_received {:s3_put, _path, _body}

    view
    |> element(~s([data-attachment-id="stable-id"] [phx-click="remove_attachment"]))
    |> render_click()

    render_click(view, "cancel_note")

    assert_patch(view, ~p"/gao_notes/notes")
    assert %Attachment{storage_file_id: storage_file_id} =
             reload_attachment(note.id, "stable-id")

    assert storage_file_id == stable.storage_file_id
    refute_received {:s3_put, _path, _body}

    {:ok, retain_view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(retain_view)

    render_submit(retain_view, "save", %{
      "gao_note" => %{
        "title" => "Retained Attachment",
        "content" => "Retained body",
        "labels" => []
      }
    })

    assert %Attachment{
             id: "stable-id",
             path: "./stable.txt",
             mime: "text/plain",
             description: "",
             storage_file_id: retained_storage_id
           } =
             reload_attachment(note.id, "stable-id")

    assert retained_storage_id == stable.storage_file_id
    refute_received {:s3_put, _path, _body}
  end

  test "aggregate attachment error keeps drafts and shows an actionable message", %{
    conn: conn,
    user: user
  } do
    assert {:ok, _owner_note} =
             GaoNote.create_note(
               %{
                 title: "Attachment Owner",
                 content: "Body",
                 attachments: [
                   text_attachment("globally-owned", "./owned.txt", "owned bytes", "")
                 ]
               },
               user
             )

    flush_storage_messages()
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)

    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "globally-owned",
        "path" => "./draft.txt",
        "description" => "Conflicting draft",
        "source" => "text",
        "text" => "draft bytes"
      }
    })

    html =
      render_submit(view, "save", %{
        "gao_note" => %{
          "title" => "Rejected Attachment Draft",
          "content" => "Body",
          "labels" => []
        }
      })

    assert html =~ ~s(id="gao-note-attachment-save-error")
    assert html =~ "already belongs to another note"
    assert html =~ "globally-owned"
    assert html =~ "./draft.txt"
    assert GaoNote.list_notes(search: "Rejected Attachment Draft") == []
    refute_received {:s3_put, _path, "draft bytes"}
  end

  test "edit cards expose authenticated raw URLs and canonical Markdown only", %{
    conn: conn,
    user: user
  } do
    png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Attachment References",
                 content: "Body",
                 attachments: [
                   %{
                     id: "diagram-id",
                     path: "./images/diagram.png",
                     mime: "image/png",
                     description: "Diagram",
                     content_base64: Base.encode64(png)
                   },
                   text_attachment("file-id", "./docs/file.txt", "private raw body", "")
                 ]
               },
               user
             )

    image = attachment_by_id(note, "diagram-id")
    file = attachment_by_id(note, "file-id")
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    html = render_async(view)

    assert html =~ "./images/diagram.png"
    assert html =~ "./docs/file.txt"
    assert html =~ "image/png"
    assert html =~ "text/plain"

    assert has_element?(
             view,
             ~s|button[data-clipboard-text="![Diagram](./images/diagram.png)"]|
           )

    assert has_element?(
             view,
             ~s|button[data-clipboard-text="[file.txt](./docs/file.txt)"]|
           )

    assert html =~
             ~s(href="/gao_notes/notes/#{note.id}/attachments/images/diagram.png")

    assert html =~ ~s(href="/gao_notes/notes/#{note.id}/attachments/docs/file.txt")
    refute html =~ image.storage_file_id
    refute html =~ file.storage_file_id
    refute html =~ "private raw body"
    refute html =~ Base.encode64(png)
  end

  test "saved Markdown rewrites only known canonical attachment links and images", %{
    conn: conn,
    user: user
  } do
    png = <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

    content = """
    [Download](./docs/report%201.txt)
    ![Preview](./images/preview.png)
    [External](https://example.com/docs)
    [Anchor](#details)
    [Unknown](./docs/unknown.txt)
    [Traversal](../private.txt)
    """

    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Rendered Attachment Markdown",
                 content: content,
                 attachments: [
                   text_attachment("report-id", "./docs/report 1.txt", "report", ""),
                   %{
                     id: "preview-id",
                     path: "./images/preview.png",
                     mime: "image/png",
                     description: "",
                     content_base64: Base.encode64(png)
                   }
                 ]
               },
               user
             )

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}")
    content_selector = "#gao-note-content-#{note.id}"

    assert has_element?(
             view,
             ~s(#{content_selector} a[href="/gao_notes/notes/#{note.id}/attachments/docs/report%201.txt"]),
             "Download"
           )

    assert has_element?(
             view,
             ~s(#{content_selector} img[src="/gao_notes/notes/#{note.id}/attachments/images/preview.png"])
           )

    assert has_element?(
             view,
             ~s(#{content_selector} a[href="https://example.com/docs"]),
             "External"
           )

    assert has_element?(view, ~s(#{content_selector} a[href="#details"]), "Anchor")
    assert has_element?(view, ~s(#{content_selector} a[href="./docs/unknown.txt"]), "Unknown")
    assert has_element?(view, ~s(#{content_selector} a[href="../private.txt"]), "Traversal")
  end

  test "persisted text is read lazily and stages replacement only after confirmation", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Lazy Text Attachment",
                 content: "Body",
                 attachments: [
                   text_attachment("editable-text", "./editable.txt", "stored text", "Editable")
                 ]
               },
               user
             )

    original = attachment_by_id(note, "editable-text")
    Application.put_env(:gsmlg_storage, :gao_note_live_test_object, "loaded on demand")
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(view)

    refute_received {:s3_get, _path}

    html =
      view
      |> element(
        ~s([data-attachment-id="editable-text"] [phx-click="open_attachment_modal"][phx-value-operation="edit_text"])
      )
      |> render_click()

    assert_receive {:s3_get, _path}
    assert html =~ "loaded on demand"
    assert has_element?(view, "#gao-note-attachment-form input[readonly][value='editable-text']")

    assert %Attachment{storage_file_id: storage_file_id} =
             reload_attachment(note.id, "editable-text")

    assert storage_file_id == original.storage_file_id
    refute_received {:s3_put, _path, _body}

    html =
      render_submit(view, "stage_attachment", %{
        "attachment" => %{
          "id" => "tampered-text-id",
          "path" => "./editable.txt",
          "description" => "Edited lazily",
          "source" => "text",
          "text" => "edited text"
        }
      })

    assert html =~ "Replacement"
    assert html =~ "editable-text"

    assert %Attachment{storage_file_id: staged_storage_id} =
             reload_attachment(note.id, "editable-text")

    assert staged_storage_id == original.storage_file_id
    refute_received {:s3_put, _path, _body}

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Lazy Text Attachment",
        "content" => "Updated body",
        "labels" => []
      }
    })

    assert %Attachment{id: "editable-text", storage_file_id: replacement_storage_id} =
             reload_attachment(note.id, "editable-text")

    refute replacement_storage_id == original.storage_file_id
    assert_receive {:s3_put, _path, "edited text"}
  end

  test "invalid persisted text reports an actionable lazy-edit error without mutation", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Invalid Lazy Text",
                 content: "Body",
                 attachments: [
                   text_attachment("invalid-text", "./invalid.txt", "stored text", "")
                 ]
               },
               user
             )

    original = attachment_by_id(note, "invalid-text")
    Application.put_env(:gsmlg_storage, :gao_note_live_test_object, <<255>>)
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(view)
    refute_received {:s3_get, _path}

    html =
      view
      |> element(
        ~s([data-attachment-id="invalid-text"] [phx-click="open_attachment_modal"][phx-value-operation="edit_text"])
      )
      |> render_click()

    assert_receive {:s3_get, _path}
    assert html =~ "not valid UTF-8 text"

    assert %Attachment{storage_file_id: storage_file_id} =
             reload_attachment(note.id, "invalid-text")

    assert storage_file_id == original.storage_file_id
    refute_received {:s3_put, _path, _body}
  end

  test "reopening a staged text edit uses draft content without rereading storage", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Reopen Staged Text",
                 content: "Body",
                 attachments: [
                   text_attachment("reopen-text", "./reopen.txt", "persisted bytes", "")
                 ]
               },
               user
             )

    Application.put_env(:gsmlg_storage, :gao_note_live_test_object, "persisted response")
    flush_storage_messages()

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    render_async(view)

    edit_text_selector =
      ~s([data-attachment-id="reopen-text"] [phx-click="open_attachment_modal"][phx-value-operation="edit_text"])

    view |> element(edit_text_selector) |> render_click()
    assert_receive {:s3_get, _path}

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "reopen-text",
        "path" => "./reopen.txt",
        "description" => "",
        "source" => "text",
        "text" => "first staged edit"
      }
    })

    flush_storage_messages()
    Application.put_env(:gsmlg_storage, :gao_note_live_test_object, "changed persisted response")

    html = view |> element(edit_text_selector) |> render_click()

    refute_received {:s3_get, _path}
    assert html =~ "first staged edit"

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "reopen-text",
        "path" => "./reopen.txt",
        "description" => "",
        "source" => "text",
        "text" => "second staged edit"
      }
    })

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Reopen Staged Text",
        "content" => "Saved",
        "labels" => []
      }
    })

    assert_receive {:s3_put, _path, "second staged edit"}
  end

  test "first selected file fills untouched ID and path without trusting browser MIME", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "client name.txt", content: "plain bytes", type: "image/png"}
      ])

    render_upload(upload, "client name.txt")
    html = render(view)
    document = Floki.parse_fragment!(html)

    assert [generated_id] = Floki.attribute(document, "#attachment_id", "value")
    assert String.starts_with?(generated_id, "attachment-")
    assert Floki.attribute(document, "#attachment_path", "value") == ["./client name.txt"]
    assert Floki.attribute(document, "#gao-note-attachment-mime", "value") == [
             "Detected from staged bytes"
           ]

    html =
      render_submit(view, "stage_attachment", %{
        "attachment" => %{
          "id" => generated_id,
          "path" => "./client name.txt",
          "description" => "",
          "source" => "file",
          "text" => ""
        }
      })

    assert html =~ "text/plain"
    refute html =~ "plain bytes"

    render_click(view, "cancel_note")
  end

  test "selected file never overwrites user-edited ID or path conveniences", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    render_change(view, "attachment_modal_changed", %{
      "_target" => ["attachment", "id"],
      "attachment" => %{
        "id" => "caller-id",
        "path" => "./data.txt",
        "description" => "",
        "source" => "file",
        "text" => ""
      }
    })

    render_change(view, "attachment_modal_changed", %{
      "_target" => ["attachment", "path"],
      "attachment" => %{
        "id" => "caller-id",
        "path" => "./caller/path.txt",
        "description" => "",
        "source" => "file",
        "text" => ""
      }
    })

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "browser-name.txt", content: "content", type: "application/octet-stream"}
      ])

    render_upload(upload, "browser-name.txt")
    document = view |> render() |> Floki.parse_fragment!()

    assert Floki.attribute(document, "#attachment_id", "value") == ["caller-id"]
    assert Floki.attribute(document, "#attachment_path", "value") == ["./caller/path.txt"]

    view
    |> element(~s([phx-click="cancel_attachment_upload"]))
    |> render_click()

    second_upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "second-browser-name.txt", content: "second", type: "image/png"}
      ])

    render_upload(second_upload, "second-browser-name.txt")
    document = view |> render() |> Floki.parse_fragment!()

    assert Floki.attribute(document, "#attachment_id", "value") == ["caller-id"]
    assert Floki.attribute(document, "#attachment_path", "value") == ["./caller/path.txt"]

    render_click(view, "cancel_attachment_modal")
  end

  test "canceling an auto-defaulted upload lets the next entry derive fresh defaults", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    first_upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "first.txt", content: "first", type: "text/plain"}
      ])

    render_upload(first_upload, "first.txt")
    first_document = view |> render() |> Floki.parse_fragment!()
    assert [first_id] = Floki.attribute(first_document, "#attachment_id", "value")
    assert Floki.attribute(first_document, "#attachment_path", "value") == ["./first.txt"]

    view
    |> element(~s([phx-click="cancel_attachment_upload"]))
    |> render_click()

    reset_document = view |> render() |> Floki.parse_fragment!()
    assert Floki.attribute(reset_document, "#attachment_id", "value") == [""]
    assert Floki.attribute(reset_document, "#attachment_path", "value") == ["./data.txt"]

    second_upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "second.txt", content: "second", type: "application/octet-stream"}
      ])

    render_upload(second_upload, "second.txt")
    second_document = view |> render() |> Floki.parse_fragment!()
    assert [second_id] = Floki.attribute(second_document, "#attachment_id", "value")
    refute second_id == first_id
    assert Floki.attribute(second_document, "#attachment_path", "value") == ["./second.txt"]

    render_click(view, "cancel_attachment_modal")
  end

  test "uploaded file drafts stay private and disk-backed through replacement and cancel", %{
    conn: conn
  } do
    before_paths = staged_temp_paths()
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "disk.txt", content: "disk-backed bytes", type: "application/octet-stream"}
      ])

    render_upload(upload, "disk.txt")

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "disk-backed",
        "path" => "./disk.txt",
        "description" => "",
        "source" => "file",
        "text" => ""
      }
    })

    assert [temp_path] = new_staged_temp_paths(before_paths)
    assert {:ok, %File.Stat{size: 17}} = File.stat(temp_path)
    refute render(view) =~ "disk-backed bytes"

    view
    |> element(
      ~s([data-attachment-id="disk-backed"] [phx-click="open_attachment_modal"][phx-value-operation="replace"])
    )
    |> render_click()

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "disk-backed",
        "path" => "./disk.txt",
        "description" => "",
        "source" => "text",
        "text" => "replacement text"
      }
    })

    refute File.exists?(temp_path)

    view
    |> element(~s([data-attachment-id="disk-backed"] [phx-click="remove_attachment"]))
    |> render_click()

    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "cancel.bin", content: <<1, 2, 3>>, type: "text/plain"}
      ])

    render_upload(upload, "cancel.bin")

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "cancel-file",
        "path" => "./cancel.bin",
        "description" => "",
        "source" => "file",
        "text" => ""
      }
    })

    assert [cancel_path] = new_staged_temp_paths(before_paths)
    assert File.exists?(cancel_path)

    render_click(view, "cancel_note")

    refute File.exists?(cancel_path)
    assert_patch(view, ~p"/gao_notes/notes")
  end

  test "explicit empty-file staging persists a zero-byte Plug.Upload and cleans its temp file", %{
    conn: conn
  } do
    before_paths = staged_temp_paths()
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    render_change(view, "attachment_modal_changed", %{
      "_target" => ["attachment", "path"],
      "attachment" => %{
        "id" => "empty-file",
        "path" => "./empty.txt",
        "description" => "Empty",
        "source" => "file",
        "text" => ""
      }
    })

    html = view |> element("#gao-note-stage-empty-attachment") |> render_click()

    assert html =~ "empty-file"
    assert html =~ "./empty.txt"
    assert html =~ "text/plain"
    assert [temp_path] = new_staged_temp_paths(before_paths)
    assert {:ok, %File.Stat{size: 0}} = File.stat(temp_path)

    render_submit(view, "save", %{
      "gao_note" => %{
        "title" => "Empty Attachment",
        "content" => "Body",
        "labels" => []
      }
    })

    assert [%Note{attachments: [%Attachment{id: "empty-file"}]}] =
             GaoNote.list_notes(search: "Empty Attachment")

    assert_receive {:s3_put, _path, ""}
    refute File.exists?(temp_path)
  end

  test "aggregate errors preserve disk drafts for retry and note cancel cleans them", %{
    conn: conn,
    user: user
  } do
    assert {:ok, _owner_note} =
             GaoNote.create_note(
               %{
                 title: "Disk Conflict Owner",
                 content: "Body",
                 attachments: [
                   text_attachment("disk-conflict", "./owned.txt", "owned", "")
                 ]
               },
               user
             )

    flush_storage_messages()
    before_paths = staged_temp_paths()
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes/new")
    render_async(view)
    render_click(view, "open_attachment_modal", %{"operation" => "new"})

    upload =
      file_input(view, "#gao-note-attachment-form", :attachment, [
        %{name: "conflict.bin", content: <<4, 5, 6>>, type: "image/png"}
      ])

    render_upload(upload, "conflict.bin")

    render_submit(view, "stage_attachment", %{
      "attachment" => %{
        "id" => "disk-conflict",
        "path" => "./conflict.bin",
        "description" => "",
        "source" => "file",
        "text" => ""
      }
    })

    assert [temp_path] = new_staged_temp_paths(before_paths)

    html =
      render_submit(view, "save", %{
        "gao_note" => %{
          "title" => "Disk Conflict Draft",
          "content" => "Body",
          "labels" => []
        }
      })

    assert html =~ "already belongs to another note"
    assert File.exists?(temp_path)
    assert GaoNote.list_notes(search: "Disk Conflict Draft") == []

    render_click(view, "cancel_note")
    refute File.exists?(temp_path)
  end

  test "show lists every attachment with authenticated metadata and download action", %{
    conn: conn,
    user: user
  } do
    assert {:ok, note} =
             GaoNote.create_note(
               %{
                 title: "Attachment Inventory",
                 content: "No attachment reference here.",
                 attachments: [
                   text_attachment(
                     "inventory-file",
                     "./docs/inventory file.txt",
                     "inventory private bytes",
                     "Inventory"
                   )
                 ]
               },
               user
             )

    attachment = attachment_by_id(note, "inventory-file")
    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}")

    assert has_element?(view, "#note-attachments")
    assert html =~ "./docs/inventory file.txt"
    assert html =~ "text/plain"
    assert html =~ "Inventory"
    assert has_element?(
             view,
             ~s(#note-attachments a[href="/gao_notes/notes/#{note.id}/attachments/docs/inventory%20file.txt"][download="inventory file.txt"]),
             "Download"
           )

    refute html =~ attachment.storage_file_id
    refute html =~ "inventory private bytes"
    refute html =~ Base.encode64("inventory private bytes")
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end

  defp note_fixture(user, title, labels \\ []) do
    assert {:ok, note} =
             GaoNote.create_note(%{title: title, content: "Batch body", labels: labels}, user)

    note
  end

  defp label_setting_fixture(name, value_type \\ "text") do
    case GaoNote.create_label_setting(%{name: name, value_type: value_type}) do
      {:ok, setting} -> setting
      {:error, _changeset} -> Enum.find(GaoNote.list_label_settings(), &(&1.name == name))
    end
  end

  defp select_notes(view, notes) do
    Enum.each(notes, fn note ->
      render_click(view, "toggle_batch_note", %{"id" => note.id})
    end)
  end

  defp change_batch_label(view, params) do
    render_change(view, "change_batch_label_action", %{"batch_label" => params})
  end

  defp submit_batch_label(view, params) do
    render_submit(view, "submit_batch_label", %{"batch_label" => params})
  end

  defp labels_for_note(note_id) do
    note_id
    |> GaoNote.get_note!()
    |> Map.fetch!(:labels)
    |> Map.new(fn label -> {label.label_setting.name, label.value || ""} end)
  end

  defp text_attachment(id, path, content, description) do
    %{
      id: id,
      path: path,
      mime: "text/plain",
      description: description,
      content_base64: Base.encode64(content)
    }
  end

  defp attachment_by_id(%Note{} = note, id) do
    Enum.find(note.attachments, &(&1.id == id))
  end

  defp reload_attachment(note_id, attachment_id) do
    note_id
    |> GaoNote.get_note!()
    |> attachment_by_id(attachment_id)
  end

  defp flush_storage_messages do
    receive do
      {:s3_put, _path, _body} -> flush_storage_messages()
      {:s3_get, _path} -> flush_storage_messages()
      {:s3_delete, _path} -> flush_storage_messages()
    after
      0 -> :ok
    end
  end

  defp staged_temp_paths do
    temp_dir = Path.join(System.tmp_dir!(), "gsmlg-admin-gao-note-attachments")

    case File.ls(temp_dir) do
      {:ok, entries} ->
        entries
        |> Enum.flat_map(fn entry ->
          editor_dir = Path.join(temp_dir, entry)

          case File.lstat(editor_dir) do
            {:ok, %{type: :directory}} ->
              case File.ls(editor_dir) do
                {:ok, files} ->
                  files
                  |> Enum.filter(&String.starts_with?(&1, "stage-"))
                  |> Enum.map(&Path.join(editor_dir, &1))

                {:error, _reason} ->
                  []
              end

            _other ->
              []
          end
        end)
        |> MapSet.new()

      {:error, :enoent} -> MapSet.new()
    end
  end

  defp new_staged_temp_paths(before_paths) do
    staged_temp_paths()
    |> MapSet.difference(before_paths)
    |> MapSet.to_list()
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
