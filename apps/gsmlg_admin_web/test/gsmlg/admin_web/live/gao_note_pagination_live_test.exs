defmodule GSMLG.AdminWeb.GaoNotePaginationLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import Ecto.Query
  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.GaoNoteLive.{Index, NotesPath}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, Log, Note}
  alias GSMLG.Repo

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

    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(Note)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      %{conn | secret_key_base: @secret_key_base}
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn, user: user}
  end

  test "loads 25 notes per page and provides accessible first and last page controls", %{
    conn: conn,
    user: user
  } do
    notes = notes_fixture(user, 56)
    {:ok, view, html} = live(conn, ~p"/gao_notes/notes")
    refute html =~ ~s(id="gao-note-pagination")
    render_async(view, 5_000)

    assert has_element?(view, ~s(#gao-note-pagination[aria-label="Notes pagination"]))
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 56 notes")
    assert has_element?(view, ~s(#gao-note-pagination [aria-label="Previous page"][disabled]))
    assert has_element?(view, ~s(#gao-note-pagination [aria-label="Page 1"][aria-current="page"]))
    assert row_ids(view) == notes |> Enum.take(25) |> Enum.map(& &1.id)

    view |> element(~s(#gao-note-pagination a[aria-label="Next page"])) |> render_click()
    assert_patch_query(view, index_path(%{page: 2}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 26–50 of 56 notes")
    assert row_ids(view) == notes |> Enum.slice(25, 25) |> Enum.map(& &1.id)

    view |> element(~s(#gao-note-pagination a[aria-label="Page 3"])) |> render_click()
    assert_patch_query(view, index_path(%{page: 3}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 51–56 of 56 notes")
    assert has_element?(view, ~s(#gao-note-pagination [aria-label="Next page"][disabled]))
    assert row_ids(view) == notes |> Enum.drop(50) |> Enum.map(& &1.id)

    view |> element(~s(#gao-note-pagination a[aria-label="Previous page"])) |> render_click()
    assert_patch_query(view, index_path(%{page: 2}))
    render_async(view, 5_000)
    assert row_ids(view) == notes |> Enum.slice(25, 25) |> Enum.map(& &1.id)
  end

  test "pagination preserves search and repeated label selectors and counts only matching live notes",
       %{conn: conn, user: user} do
    matching = notes_fixture(user, 26, "Filtered & precise", ["topic=ecto", "project=two words"])
    notes_fixture(user, 3, "Filtered & precise", ["topic=other", "project=two words"])
    notes_fixture(user, 2, "Different title", ["topic=ecto", "project=two words"])
    [deleted] = notes_fixture(user, 1, "Filtered & precise", ["topic=ecto", "project=two words"])
    assert {:ok, _} = GaoNote.delete_note(deleted, user)

    filters = %{"search" => "Filtered & precise", "labels" => ["topic=ecto", "project=two words"]}
    {:ok, view, _html} = live(conn, index_path(filters))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")

    next_query = view |> link_query("Next page")
    assert_query(next_query, Map.merge(filters, %{"page" => "2", "page_size" => "25"}))
    view |> element(~s(#gao-note-pagination a[aria-label="Next page"])) |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 26–26 of 26 notes")
    assert row_ids(view) == matching |> Enum.drop(25) |> Enum.map(& &1.id)

    assert_query(
      link_query(view, "Previous page"),
      Map.merge(filters, %{"page" => "1", "page_size" => "25"})
    )
  end

  test "invalid page values use page one and overlarge pages clamp and patch to the last page", %{
    conn: conn,
    user: user
  } do
    notes = notes_fixture(user, 26)
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes?page=invalid")
    render_async(view, 5_000)

    for page <- ["0", "-1", "1.5", "2junk"] do
      render_patch(view, "/gao_notes/notes?page=" <> page)
      render_async(view, 5_000)
      assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")
      assert row_ids(view) == notes |> Enum.take(25) |> Enum.map(& &1.id)
    end

    render_patch(view, ~p"/gao_notes/notes?page=999")
    render_async(view, 5_000)
    assert_patch(view, index_path(%{page: 2}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 26–26 of 26 notes")
    assert row_ids(view) == notes |> Enum.drop(25) |> Enum.map(& &1.id)
  end

  test "empty results show an empty count and cannot navigate to negative or missing pages", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes?page=5")
    render_async(view, 5_000)
    assert_patch(view, index_path())
    render_async(view, 5_000)

    assert has_element?(view, "#gao-note-pagination-summary", "0 notes")
    assert render(view) =~ "No notes found"
    assert row_ids(view) == []
    assert has_element?(view, ~s(#gao-note-pagination [aria-label="Previous page"][disabled]))
    assert has_element?(view, ~s(#gao-note-pagination [aria-label="Next page"][disabled]))
  end

  test "select all is restricted to the current page and page changes clear selection", %{
    conn: conn,
    user: user
  } do
    [first | _] = notes_fixture(user, 26)
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
    render_async(view, 5_000)
    render_click(view, "toggle_all_batch_notes")
    assert has_element?(view, "#gao-note-batch-toolbar", "25 selected")

    view |> element(~s(#gao-note-pagination a[aria-label="Next page"])) |> render_click()
    render_async(view, 5_000)
    refute has_element?(view, "#gao-note-batch-toolbar")
    assert has_element?(view, "#gao-note-select-all[data-state='none']")
    render_click(view, "toggle_batch_note", %{"id" => first.id})
    refute has_element?(view, "#gao-note-batch-toolbar")
    render_click(view, "toggle_all_batch_notes")
    assert has_element?(view, "#gao-note-batch-toolbar", "1 selected")

    view |> element(~s(#gao-note-pagination a[aria-label="Previous page"])) |> render_click()
    render_async(view, 5_000)
    refute has_element?(view, "#gao-note-batch-toolbar")
    assert has_element?(view, "#gao-note-select-all[data-state='none']")
  end

  test "search and label filter changes reset to page one", %{conn: conn, user: user} do
    notes_fixture(user, 26, "Reset target", ["topic=ecto"])
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes?page=2")
    render_async(view, 5_000)

    view
    |> form("#gao-note-filter-form", %{"filters" => %{"search" => "Reset"}})
    |> render_submit()

    assert_patch(view, index_path(%{search: "Reset"}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")

    render_patch(view, ~p"/gao_notes/notes?search=Reset&page=2")
    render_async(view, 5_000)

    render_change(view, "search_form_changed", %{
      "filters" => %{"search" => "Reset"},
      "label_filter" => %{"key" => "topic", "value" => "ecto"}
    })

    render_click(view, "add_search_filter")
    assert_patch(view, index_path(%{search: "Reset", labels: ["topic=ecto"]}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")

    render_patch(view, index_path(%{search: "Reset", labels: ["topic=ecto"], page: 2}))
    render_async(view, 5_000)
    render_click(view, "remove_search_filter", %{"filter" => "topic=ecto"})
    assert_patch(view, index_path(%{search: "Reset"}))
    render_async(view, 5_000)

    render_patch(view, ~p"/gao_notes/notes?search=Reset&page=2")
    render_async(view, 5_000)
    render_click(view, "clear_search_filters")
    assert_patch(view, index_path())
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")
  end

  test "deleting the only note on the last page keeps filters and returns to the last valid page",
       %{
         conn: conn,
         user: user
       } do
    notes = notes_fixture(user, 26, "Keep filtered", ["topic=ecto"])
    notes_fixture(user, 3, "Unrelated", [])
    filters = %{search: "Keep filtered", labels: ["topic=ecto"], page: 2}
    {:ok, view, _html} = live(conn, index_path(filters))
    render_async(view, 5_000)
    [last] = Enum.drop(notes, 25)

    view
    |> element(~s(#gao-note-delete-list-confirm-#{last.id} [phx-click="delete"]))
    |> render_click()

    assert_patch(view, index_path(filters))
    render_async(view, 5_000)
    assert_patch(view, index_path(Map.delete(filters, :page)))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 25 notes")
    refute has_element?(view, "#gao-note-row-#{last.id}")
    refute render(view) =~ "Unrelated"
    assert %Note{} = GaoNote.get_deleted_note(last.id)
  end

  test "batch deletion stays on the active page then clamps when the last page disappears", %{
    conn: conn,
    user: user
  } do
    notes_fixture(user, 13, "Batch filtered", ["topic=ecto"])
    filters = %{search: "Batch filtered", labels: ["topic=ecto"], page: 2, page_size: 10}
    {:ok, view, _html} = live(conn, index_path(filters))
    render_async(view, 5_000)
    [one | _] = row_ids(view)
    render_click(view, "toggle_batch_note", %{"id" => one})
    render_click(view, "batch_delete_notes")
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 11–12 of 12 notes")
    refute has_element?(view, "#gao-note-batch-toolbar")

    render_click(view, "toggle_all_batch_notes")
    assert has_element?(view, "#gao-note-batch-toolbar", "2 selected")
    render_click(view, "batch_delete_notes")
    render_async(view, 5_000)
    assert_patch(view, index_path(Map.delete(filters, :page)))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–10 of 10 notes")
    refute has_element?(view, "#gao-note-batch-toolbar")
  end

  test "stale async page and filter results cannot replace the active page", %{
    conn: conn,
    user: user
  } do
    notes_fixture(user, 26)
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes?page=2")
    render_async(view, 5_000)
    socket = :sys.get_state(view.pid).socket

    result = %{
      filters: socket.assigns.active_filters,
      requested_page: 1,
      page_size: 25,
      page: 1,
      total_notes: 1,
      total_pages: 1,
      notes: [],
      label_settings: []
    }

    assert {:noreply, ^socket} = Index.handle_async(:load_batch_index, {:ok, result}, socket)

    result = %{result | requested_page: 2, filters: %{"search" => "old", "labels" => []}}
    assert {:noreply, ^socket} = Index.handle_async(:load_batch_index, {:ok, result}, socket)

    result = %{result | filters: socket.assigns.active_filters, page_size: 50}
    assert {:noreply, ^socket} = Index.handle_async(:load_batch_index, {:ok, result}, socket)
  end

  test "supported URL page sizes restore the selector and fetch the correct page boundaries", %{
    conn: conn,
    user: user
  } do
    notes = notes_fixture(user, 101)

    for size <- [10, 50, 100] do
      {:ok, view, _html} = live(conn, index_path(%{page: 2, page_size: size}))
      render_async(view, 5_000)

      assert has_element?(view, ~s(#gao-note-page-size-form[phx-change="change_page_size"]))

      assert has_element?(
               view,
               ~s(#gao-note-page-size[name="page_size"] option[value="#{size}"][selected])
             )

      assert view
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.find("#gao-note-page-size option")
             |> Floki.attribute("value") == ["10", "25", "50", "100"]

      assert row_ids(view) == notes |> Enum.slice(size, size) |> Enum.map(& &1.id)

      assert has_element?(
               view,
               "#gao-note-pagination-summary",
               "Showing #{size + 1}–#{min(size * 2, 101)} of 101 notes"
             )

      assert link_query(view, "Previous page") == %{
               "page" => "1",
               "page_size" => Integer.to_string(size)
             }

      refute_push_event(view, "gao-note-page-size", %{})
    end
  end

  test "unsaved preferences use 25 without rewriting the initial URL", %{conn: conn, user: user} do
    notes_fixture(user, 26)
    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes")
    render_async(view, 5_000)

    assert has_element?(view, ~s(#gao-note-page-size option[value="25"][selected]))
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–25 of 26 notes")
    refute_patched(view)
    refute_push_event(view, "gao-note-page-size", %{})
  end

  test "saved connect preferences are restored but an explicit URL size wins", %{
    conn: conn,
    user: user
  } do
    notes_fixture(user, 61)

    for saved <- [50, "50"] do
      saved_conn = put_connect_params(conn, %{"gao_note_page_size" => saved})
      {:ok, view, _html} = live(saved_conn, ~p"/gao_notes/notes")
      render_async(view, 5_000)
      assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–50 of 61 notes")
      assert has_element?(view, ~s(#gao-note-page-size option[value="50"][selected]))
      refute_push_event(view, "gao-note-page-size", %{})

      render_patch(view, ~p"/gao_notes/notes")
      assert_patch(view, index_path(%{page_size: 50}))
      render_async(view, 5_000)
      assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–50 of 61 notes")
      refute_push_event(view, "gao-note-page-size", %{})

      {:ok, explicit_view, _html} = live(saved_conn, index_path(%{page_size: 10, page: 2}))
      render_async(explicit_view, 5_000)

      assert has_element?(
               explicit_view,
               "#gao-note-pagination-summary",
               "Showing 11–20 of 61 notes"
             )

      assert has_element?(explicit_view, ~s(#gao-note-page-size option[value="10"][selected]))
      refute_patched(explicit_view)
      refute_push_event(explicit_view, "gao-note-page-size", %{})
    end
  end

  test "invalid URL sizes canonicalize to the saved preference or default without saving", %{
    conn: conn
  } do
    for saved <- [nil, "50"] do
      sized_conn = put_connect_params(conn, %{"gao_note_page_size" => saved})
      effective_size = if saved, do: 50, else: 25
      {:ok, view, _html} = live(sized_conn, index_path(%{page_size: effective_size}))
      render_async(view, 5_000)

      for invalid <- [
            "0",
            "-1",
            "11",
            "1000000",
            "25junk",
            "10.0",
            "",
            ["10"],
            %{"value" => "10"}
          ] do
        query = Plug.Conn.Query.encode(%{"page_size" => invalid, "search" => "retained"})
        render_patch(view, "/gao_notes/notes?" <> query)
        render_async(view, 5_000)
        assert_patch(view, index_path(%{page_size: effective_size, search: "retained"}))
        render_async(view, 5_000)

        assert has_element?(
                 view,
                 ~s(#gao-note-page-size option[value="#{effective_size}"][selected])
               )

        refute_push_event(view, "gao-note-page-size", %{})
      end
    end
  end

  test "invalid saved connect preferences fall back to 25", %{conn: conn} do
    for saved <- [nil, "bad", "11", -1, [50], %{"value" => 50}] do
      sized_conn = put_connect_params(conn, %{"gao_note_page_size" => saved})
      {:ok, view, _html} = live(sized_conn, ~p"/gao_notes/notes")
      render_async(view, 5_000)
      assert has_element?(view, ~s(#gao-note-page-size option[value="25"][selected]))
      refute_patched(view)
      refute_push_event(view, "gao-note-page-size", %{})
    end
  end

  test "changing size saves only the explicit choice, preserves filters and clears page selection",
       %{conn: conn, user: user} do
    notes_fixture(user, 61, "Sized notes", ["topic=ecto", "project=demo"])
    filters = %{search: "Sized", labels: ["topic=ecto"], page: 2, page_size: 10}
    {:ok, view, _html} = live(conn, index_path(filters))
    render_async(view, 5_000)
    render_click(view, "toggle_all_batch_notes")
    assert has_element?(view, "#gao-note-batch-toolbar", "10 selected")

    view |> form("#gao-note-page-size-form", %{"page_size" => "50"}) |> render_change()
    assert_patch(view, index_path(%{filters | page: 1, page_size: 50}))
    assert_push_event(view, "gao-note-page-size", %{page_size: 50})
    render_async(view, 5_000)
    refute has_element?(view, "#gao-note-batch-toolbar")
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–50 of 61 notes")

    assert_query(link_query(view, "Next page"), %{
      "search" => "Sized",
      "labels" => ["topic=ecto"],
      "page" => "2",
      "page_size" => "50"
    })

    for invalid <- ["11", "25junk", ["10"], %{"value" => "10"}] do
      render_change(view, "change_page_size", %{"page_size" => invalid})
      refute_patched(view)
      refute_push_event(view, "gao-note-page-size", %{})
      assert has_element?(view, ~s(#gao-note-page-size option[value="50"][selected]))
    end

    render_submit(view, "search", %{
      "filters" => %{"search" => "Sized notes", "labels" => ["topic=ecto"]}
    })

    assert_patch(
      view,
      index_path(%{search: "Sized notes", labels: ["topic=ecto"], page_size: 50})
    )

    render_async(view, 5_000)

    render_change(view, "search_form_changed", %{
      "filters" => %{"search" => "Sized notes", "labels" => ["topic=ecto"]},
      "label_filter" => %{"key" => "project", "value" => "demo"}
    })

    render_click(view, "add_search_filter")

    assert_patch(
      view,
      index_path(%{search: "Sized notes", labels: ["topic=ecto", "project=demo"], page_size: 50})
    )

    render_async(view, 5_000)
    render_click(view, "remove_search_filter", %{"filter" => "project=demo"})

    assert_patch(
      view,
      index_path(%{search: "Sized notes", labels: ["topic=ecto"], page_size: 50})
    )

    render_async(view, 5_000)
    render_click(view, "clear_search_filters")
    assert_patch(view, index_path(%{page_size: 50}))
    render_async(view, 5_000)
    assert has_element?(view, ~s(#gao-note-page-size option[value="50"][selected]))
    refute_push_event(view, "gao-note-page-size", %{})
  end

  test "clamping and deleting a last page preserve a nondefault size", %{conn: conn, user: user} do
    notes_fixture(user, 11, "Small pages", ["topic=ecto"])
    filters = %{search: "Small pages", labels: ["topic=ecto"], page: 999, page_size: 10}
    {:ok, view, _html} = live(conn, index_path(filters))
    render_async(view, 5_000)
    assert_patch(view, index_path(%{filters | page: 2}))
    render_async(view, 5_000)
    [last_id] = row_ids(view)

    view
    |> element(~s(#gao-note-delete-list-confirm-#{last_id} [phx-click="delete"]))
    |> render_click()

    assert_patch(view, index_path(%{filters | page: 2}))
    render_async(view, 5_000)
    assert_patch(view, index_path(%{filters | page: 1}))
    render_async(view, 5_000)
    assert has_element?(view, "#gao-note-pagination-summary", "Showing 1–10 of 10 notes")
    assert has_element?(view, ~s(#gao-note-page-size option[value="10"][selected]))
    refute_push_event(view, "gao-note-page-size", %{})
  end

  test "notes paths preserve escaped filters and omit the default page" do
    filters = %{search: "a & b?# 中", labels: ["topic=a&b", "project=two words"]}
    first = NotesPath.index(Map.put(filters, :page, 1)) |> URI.parse()
    assert first.path == "/gao_notes/notes"

    assert_query(Plug.Conn.Query.decode(first.query), %{
      "search" => filters.search,
      "labels" => filters.labels
    })

    second = NotesPath.index(Map.put(filters, :page, 2)) |> URI.parse()

    assert_query(Plug.Conn.Query.decode(second.query), %{
      "search" => filters.search,
      "labels" => filters.labels,
      "page" => "2"
    })

    for size <- [10, 25, 50, 100] do
      path = NotesPath.index(Map.merge(filters, %{page: 2, page_size: size})) |> URI.parse()

      assert_query(Plug.Conn.Query.decode(path.query), %{
        "search" => filters.search,
        "labels" => filters.labels,
        "page" => "2",
        "page_size" => Integer.to_string(size)
      })
    end

    for invalid <- [0, -1, 11, "50", [50], %{"value" => 50}] do
      path = NotesPath.index(Map.put(filters, :page_size, invalid)) |> URI.parse()

      assert_query(Plug.Conn.Query.decode(path.query), %{
        "search" => filters.search,
        "labels" => filters.labels
      })
    end
  end

  defp index_path(filters \\ %{}) do
    NotesPath.index(Map.put_new(filters, :page_size, 25))
  end

  defp assert_patch_query(view, expected_path) do
    actual = view |> assert_patch() |> URI.parse()
    expected = URI.parse(expected_path)
    assert actual.path == expected.path

    assert Plug.Conn.Query.decode(actual.query || "") ==
             Plug.Conn.Query.decode(expected.query || "")
  end

  defp assert_query(actual, expected) do
    assert Map.delete(actual, "labels") == Map.delete(expected, "labels")
    assert Enum.sort(Map.fetch!(actual, "labels")) == Enum.sort(Map.fetch!(expected, "labels"))
  end

  defp notes_fixture(user, count, title \\ "Paged note", labels \\ []) do
    for index <- 1..count do
      assert {:ok, note} =
               GaoNote.create_note(
                 %{title: "#{title} #{index}", content: "Page body", labels: labels},
                 user
               )

      updated_at = DateTime.add(~U[2026-01-01 00:00:00.000000Z], -index, :second)

      Repo.update_all(from(note in Note, where: note.id == ^note.id),
        set: [updated_at: updated_at]
      )

      note
    end
  end

  defp row_ids(view) do
    view
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.find("[id^='gao-note-row-']")
    |> Floki.attribute("id")
    |> Enum.map(&String.replace_prefix(&1, "gao-note-row-", ""))
  end

  defp link_query(view, label) do
    [href] =
      view
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find(~s(#gao-note-pagination a[aria-label="#{label}"]))
      |> Floki.attribute("href")

    href |> URI.parse() |> Map.fetch!(:query) |> Plug.Conn.Query.decode()
  end
end
