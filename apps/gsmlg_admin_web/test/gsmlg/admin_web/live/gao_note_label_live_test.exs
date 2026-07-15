defmodule GSMLG.AdminWeb.GaoNoteLabelLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.GaoNote

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
