defmodule GSMLG.AdminWeb.GaoNoteDashboardLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.GaoNoteLive.{DashboardLive, NotesPath}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{CategorySetting, Label, LabelSetting, Note}
  alias GSMLG.Repo
  alias Phoenix.LiveView.AsyncResult

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

    Repo.delete_all(CategorySetting)
    Repo.delete_all(Label)
    Repo.delete_all(Note)
    Repo.delete_all(LabelSetting)

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

  test "dashboard requires authentication" do
    conn = Phoenix.ConnTest.build_conn() |> with_secret_key_base()

    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, ~p"/gao_notes")
  end

  test "empty dashboard invites the administrator to configure Category labels", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/gao_notes")

    assert html =~ ~s(id="gao-note-categories-loading")

    html = render_async(view)

    assert html =~ "No Category labels configured."

    assert html
           |> Floki.parse_fragment!()
           |> Floki.find("main")
           |> length() == 1

    assert has_element?(
             view,
             ~s(a[href="/gao_notes/label_settings"]),
             "Configure Category labels"
           )

    refute html =~ "No notes in this category."
  end

  test "renders configured groups in order with descriptions, counts, exact links, and empty selectors",
       %{
         conn: conn,
         user: user
       } do
    project = label_setting_fixture("project", "Projects grouped by label value")
    type = label_setting_fixture("type", "Workflow kind")

    assert {:ok, _categories} =
             GaoNote.save_category_settings([
               %{label_setting_id: type.id, value: "missing"},
               %{label_setting_id: project.id},
               %{label_setting_id: type.id, value: "skill"}
             ])

    note_fixture(user, "Alpha project", ["project=alpha & beta/γ", "type=skill"])
    note_fixture(user, "Second alpha project", ["project=alpha & beta/γ"])

    {:ok, view, _html} = live(conn, ~p"/gao_notes")
    html = render_async(view)

    assert html =~ "Projects grouped by label value"
    assert html =~ "Workflow kind"
    assert html =~ "alpha &amp; beta/γ · 2"
    assert html =~ "skill · 1"

    assert ordered_ids(html, [
             "gao-note-category-0",
             "gao-note-category-1",
             "gao-note-category-2"
           ])

    assert has_element?(view, "#gao-note-category-0", "type=missing")
    assert has_element?(view, "#gao-note-category-0", "No notes in this category.")
    assert has_element?(view, "#gao-note-category-1", "project")
    assert has_element?(view, "#gao-note-category-2", "type=skill")

    selector =
      ~s(a[aria-label="Filter notes by project=alpha & beta/γ, 2 active notes"])

    assert has_element?(view, selector, "alpha & beta/γ · 2")

    [href] =
      view |> element(selector) |> render() |> Floki.parse_fragment!() |> Floki.attribute("href")

    assert %{"labels" => ["project=alpha & beta/γ"]} = decode_query(href)
  end

  test "shared Notes path serializer preserves plural exact labels and special characters" do
    path = NotesPath.exact_label("alpha & beta/γ", "plus+equal= spaced value")

    assert URI.parse(path).path == "/gao_notes/notes"

    assert %{"labels" => ["alpha & beta/γ=plus+equal= spaced value"]} =
             decode_query(path)

    assert %{"labels" => ["topic=ecto"], "search" => "one + two = three"} =
             NotesPath.index(%{search: "one + two = three", labels: ["topic=ecto"]})
             |> decode_query()
  end

  test "failed async presentation shows only the unavailable state" do
    result = AsyncResult.loading() |> AsyncResult.failed(:database_unavailable)

    html = render_component(&DashboardLive.category_groups/1, category_groups: result)

    assert html =~ "Category dashboard is unavailable."
    refute html =~ "No Category labels configured."
    refute html =~ "No notes in this category."
    refute html =~ "active notes"
  end

  defp label_setting_fixture(name, description) do
    assert {:ok, label_setting} =
             GaoNote.create_label_setting(%{name: name, description: description})

    label_setting
  end

  defp note_fixture(user, title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: title, content: "Dashboard content", labels: labels},
               user
             )

    note
  end

  defp ordered_ids(html, ids) do
    positions = Enum.map(ids, &(:binary.match(html, ~s(id="#{&1}")) |> elem(0)))
    positions == Enum.sort(positions)
  end

  defp decode_query(path) do
    path
    |> URI.parse()
    |> Map.fetch!(:query)
    |> Plug.Conn.Query.decode()
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end
end
