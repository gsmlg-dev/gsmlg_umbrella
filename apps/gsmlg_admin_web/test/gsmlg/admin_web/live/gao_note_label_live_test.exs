defmodule GSMLG.AdminWeb.GaoNoteLabelLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{CategorySetting, LabelSetting}
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

    Repo.delete_all(CategorySetting)
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

  test "label filter returns only matching notes", %{conn: conn, user: user} do
    matching = note_fixture(user, "Admin matching label", ["topic=ecto"])
    _other = note_fixture(user, "Admin other label", ["topic=phoenix"])

    {:ok, view, _html} = live(conn, ~p"/gao_notes/notes?#{%{label: "topic=ecto"}}")
    html = render_async(view)

    assert html =~ matching.title
    refute html =~ "Admin other label"
  end

  test "editing a labeled note uses its preloaded key=value label", %{conn: conn, user: user} do
    note = note_fixture(user, "Admin labeled edit", ["topic=ecto"])

    {:ok, view, html} = live(conn, ~p"/gao_notes/notes/#{note.id}/edit")
    html = html <> render_async(view)

    assert html =~ "topic=ecto"
  end

  test "label setting forms keep unique controls after the connected render", %{conn: conn} do
    label_settings =
      for name <- ["topic", "project"] do
        assert {:ok, label_setting} = GaoNote.create_label_setting(%{name: name})
        label_setting
      end

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    html = render_async(view)

    control_ids =
      html
      |> Floki.parse_fragment!()
      |> Floki.find(
        "#gao-note-label-setting-create-modal input.input[id], " <>
          "#gao-note-label-setting-create-modal select.select[id], " <>
          "[id^='gao-note-label-setting-edit-modal-'] input.input[id], " <>
          "[id^='gao-note-label-setting-edit-modal-'] select.select[id]"
      )
      |> Floki.attribute("id")

    assert length(control_ids) == 12
    assert MapSet.size(MapSet.new(control_ids)) == length(control_ids)
    refute has_element?(view, "[id^='gao-note-label-setting-edit-form-'] input[name='id']")

    topic = Enum.find(label_settings, &(&1.name == "topic"))

    view
    |> form("#gao-note-label-setting-edit-form-#{topic.id}", %{
      "gao_note_label_setting" => %{"name" => "topic-updated"}
    })
    |> render_submit()

    assert %LabelSetting{name: "topic-updated"} = GaoNote.get_label_setting!(topic.id)
  end

  test "builds an ordered category draft, blocks normalized duplicates, and saves same-key values",
       %{
         conn: conn
       } do
    project = label_setting_fixture(%{name: "project"})
    type = label_setting_fixture(%{name: "type"})

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    render_async(view)

    add_category(view, project.id, "")
    add_category(view, type.id, " skill ")
    add_category(view, type.id, "agent")

    assert has_element?(view, ~s(span.chip[data-selector="project"]), "project")
    assert has_element?(view, ~s(span.chip[data-selector="type=skill"]), "type=skill")
    assert has_element?(view, ~s(span.chip[data-selector="type=agent"]), "type=agent")

    assert has_element?(
             view,
             ~s(span.chip[data-selector="type=skill"] > button.chip-close[aria-label="Remove category type=skill"])
           )

    html = add_category(view, type.id, "skill")
    assert html =~ "That category selector is already selected."

    assert view
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.find("#gao-note-category-selection span.chip")
           |> length() == 3

    view
    |> element(
      ~s(span.chip[data-selector="type=skill"] > button.chip-close[phx-click="remove_category"][phx-value-label_setting_id="#{type.id}"][phx-value-value="skill"])
    )
    |> render_click()

    add_category(view, type.id, "skill")

    assert ordered_selectors(render(view), ["project", "type=agent", "type=skill"])

    view |> element("#gao-note-category-save") |> render_click()

    assert [
             %{key: "project", configured_value: nil},
             %{key: "type", configured_value: "agent"},
             %{key: "type", configured_value: "skill"}
           ] = GaoNote.list_category_groups()

    assert render_async(view) =~ "Category labels saved."
  end

  test "a duplicate delayed remove event cannot remove a neighboring selector", %{conn: conn} do
    project = label_setting_fixture(%{name: "project"})
    type = label_setting_fixture(%{name: "type"})

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    render_async(view)

    add_category(view, project.id, "")
    add_category(view, type.id, "agent")
    add_category(view, type.id, "skill")

    remove_params = %{"label_setting_id" => type.id, "value" => "agent"}

    render_hook(view, "remove_category", remove_params)
    html = render_hook(view, "remove_category", remove_params)

    assert html =~ "That category selection is no longer available."
    assert ordered_selectors(html, ["project", "type=skill"])
    refute html =~ ~s(data-selector="type=agent")
  end

  test "removing every persisted selector and saving clears Category labels", %{conn: conn} do
    project = label_setting_fixture(%{name: "project"})
    assert {:ok, [_category]} = GaoNote.save_category_settings([%{label_setting_id: project.id}])

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    render_async(view)

    assert has_element?(view, ~s(span.chip[data-selector="project"]), "project")

    view
    |> element(
      ~s(span.chip[data-selector="project"] > button.chip-close[phx-click="remove_category"][phx-value-label_setting_id="#{project.id}"][phx-value-value=""])
    )
    |> render_click()

    refute has_element?(view, "#gao-note-category-selection span.chip")

    view |> element("#gao-note-category-save") |> render_click()

    assert GaoNote.list_category_groups() == []
    assert render_async(view) =~ "Category labels saved."
  end

  test "invalid typed exact values remain in the draft when saving reports precise feedback", %{
    conn: conn
  } do
    year = label_setting_fixture(%{name: "year", value_type: "year"})

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    render_async(view)

    add_category(view, year.id, "20x6")
    assert has_element?(view, ~s(span.chip[data-selector="year=20x6"]), "year=20x6")

    html = view |> element("#gao-note-category-save") |> render_click()

    assert html =~ "Category value for year must be YYYY."
    assert GaoNote.list_category_groups() == []
    assert has_element?(view, ~s(span.chip[data-selector="year=20x6"]), "year=20x6")
  end

  test "persisted category use disables deletion and domain errors retain the removal instruction",
       %{
         conn: conn
       } do
    project = label_setting_fixture(%{name: "project"})
    assert {:ok, [_category]} = GaoNote.save_category_settings([%{label_setting_id: project.id}])

    {:ok, view, _html} = live(conn, ~p"/gao_notes/label_settings")
    render_async(view)

    instruction =
      "Remove every category using this label from Category labels before deleting it."

    assert has_element?(
             view,
             ~s(#gao-note-label-setting-delete-#{project.id}[disabled][title="#{instruction}"])
           )

    description_id = "gao-note-label-setting-delete-instruction-#{project.id}"

    assert has_element?(
             view,
             ~s(#gao-note-label-setting-delete-help-#{project.id}[tabindex="0"][aria-describedby="#{description_id}"])
           )

    assert has_element?(view, "##{description_id}", instruction)

    refute has_element?(
             view,
             ~s(#gao-note-label-setting-delete-#{project.id}[phx-click="delete"])
           )

    html = render_hook(view, "delete", %{"id" => project.id})
    assert html =~ instruction
  end

  defp note_fixture(user, title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: title, content: "Admin label content", labels: labels},
               user
             )

    note
  end

  defp label_setting_fixture(attrs) do
    assert {:ok, label_setting} = GaoNote.create_label_setting(attrs)
    label_setting
  end

  defp add_category(view, label_setting_id, value) do
    view
    |> form("#gao-note-category-form", %{
      "category" => %{"label_setting_id" => label_setting_id, "value" => value}
    })
    |> render_change()

    view |> element("#gao-note-category-add") |> render_click()
  end

  defp ordered_selectors(html, selectors) do
    positions =
      Enum.map(selectors, fn selector ->
        html |> :binary.match(~s(data-selector="#{selector}")) |> elem(0)
      end)

    positions == Enum.sort(positions)
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end
end
