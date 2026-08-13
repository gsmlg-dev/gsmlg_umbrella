defmodule GSMLG.AdminWeb.GaoNoteLabelLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.LabelSetting
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

  defp note_fixture(user, title, labels) do
    assert {:ok, note} =
             GaoNote.create_note(
               %{title: title, content: "Admin label content", labels: labels},
               user
             )

    note
  end

  defp with_secret_key_base(conn) do
    %{conn | secret_key_base: @secret_key_base}
  end
end
