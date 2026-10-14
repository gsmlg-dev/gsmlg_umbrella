defmodule GSMLG.AdminWeb.GaoNoteSettingsLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.AdminWeb.GaoNoteLive.SettingsLive

  @secret_key_base String.duplicate("a", 64)
  @settings_path "/gao_notes/settings"

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    previous =
      for {app, key} <- [
            {:gsmlg_gao_note, :storage_path},
            {:gsmlg_config, :loaded_config_path},
            {:gsmlg_config, :loaded_config}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    temp_dir =
      Path.join(System.tmp_dir!(), "gao-note-settings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(temp_dir)
    config_path = Path.join(temp_dir, "settings.toml")
    config = "# Keep this comment\n[gao_note]\nsearch_token = \"keep-token\"\n"
    File.write!(config_path, config)

    Application.delete_env(:gsmlg_gao_note, :storage_path)
    Application.put_env(:gsmlg_config, :loaded_config_path, config_path)

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
      File.rm_rf!(temp_dir)
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

    %{conn: conn, config_path: config_path, original_config: config, temp_dir: temp_dir}
  end

  test "settings route requires authentication" do
    conn = Phoenix.ConnTest.build_conn() |> with_secret_key_base()

    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(conn, @settings_path)
  end

  test "connected mount rejects an invalid token after an authenticated HTTP render", %{
    conn: conn,
    config_path: config_path,
    original_config: original_config
  } do
    conn = get(conn, @settings_path)
    assert conn.status == 200

    private =
      Map.update!(conn.private, :plug_session, fn session ->
        Map.put(session, "guardian_default_token", "invalid-guardian-token")
      end)

    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(%{conn | private: private})
    assert File.read!(config_path) == original_config
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == nil
  end

  test "save without a current user leaves TOML and runtime unchanged", %{
    config_path: config_path,
    original_config: original_config
  } do
    socket = %Phoenix.LiveView.Socket{
      endpoint: GSMLG.AdminWeb.Endpoint,
      transport_pid: self(),
      assigns: %{__changed__: %{}, flash: %{}, current_user: nil}
    }

    assert {:noreply, redirected} =
             SettingsLive.handle_event(
               "save",
               %{"gao_note" => %{"storage_path" => "unauthorized-notes"}},
               socket
             )

    assert {:redirect, %{to: "/sign_in", status: 302}} = redirected.redirected
    assert File.read!(config_path) == original_config
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == nil
  end

  test "renders the default storage path in the admin shell", %{conn: conn} do
    {:ok, view, html} = live(conn, @settings_path)

    assert html =~ "GaoNote Settings"
    assert has_element?(view, "#gao-note-settings-form")
    assert has_element?(view, ~s(input[name="gao_note[storage_path]"][value="gaonote"]))
    assert has_element?(view, "main")

    assert has_element?(
             view,
             ~s(a[href="/gao_notes/settings"][aria-current="page"]),
             "Settings"
           )
  end

  test "renders the current configured storage path", %{conn: conn} do
    Application.put_env(:gsmlg_gao_note, :storage_path, "current-notes")
    {:ok, view, _html} = live(conn, @settings_path)

    assert has_element?(view, ~s(input[name="gao_note[storage_path]"][value="current-notes"]))
  end

  test "saves to the active TOML file and persists across remount", %{
    conn: conn,
    config_path: config_path
  } do
    {:ok, view, _html} = live(conn, @settings_path)

    html =
      view
      |> form("#gao-note-settings-form", gao_note: %{storage_path: "Notes_2026-backup"})
      |> render_submit()

    assert html =~ "GaoNote settings saved."
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "Notes_2026-backup"
    assert {:ok, config} = Toml.decode_file(config_path)
    assert config["gao_note"]["storage_path"] == "Notes_2026-backup"
    assert config["gao_note"]["search_token"] == "keep-token"
    assert File.read!(config_path) =~ "# Keep this comment"

    {:ok, remounted, _html} = live(conn, @settings_path)

    assert has_element?(
             remounted,
             ~s(input[name="gao_note[storage_path]"][value="Notes_2026-backup"])
           )
  end

  test "validation preserves the invalid value and leaves disk and runtime unchanged", %{
    conn: conn,
    config_path: config_path,
    original_config: original_config
  } do
    Application.put_env(:gsmlg_gao_note, :storage_path, "previous")
    {:ok, view, _html} = live(conn, @settings_path)

    html =
      view
      |> form("#gao-note-settings-form", gao_note: %{storage_path: "../bad path"})
      |> render_change()

    assert html =~ "Use only letters, numbers, hyphens (-), and underscores (_)."
    assert has_element?(view, ~s(input[name="gao_note[storage_path]"][value="../bad path"]))
    assert File.read!(config_path) == original_config
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "previous"

    html =
      view
      |> form("#gao-note-settings-form", gao_note: %{storage_path: "../bad path"})
      |> render_submit()

    refute html =~ "GaoNote settings saved."
    assert File.read!(config_path) == original_config
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "previous"
  end

  test "write failure preserves the entered value and the active runtime path", %{
    conn: conn,
    temp_dir: temp_dir
  } do
    Application.put_env(:gsmlg_gao_note, :storage_path, "previous")
    Application.put_env(:gsmlg_config, :loaded_config_path, temp_dir)
    {:ok, view, _html} = live(conn, @settings_path)

    html =
      view
      |> form("#gao-note-settings-form", gao_note: %{storage_path: "new-notes"})
      |> render_submit()

    assert html =~ "Could not save GaoNote settings"
    refute html =~ "GaoNote settings saved."
    assert has_element?(view, ~s(input[name="gao_note[storage_path]"][value="new-notes"]))
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == "previous"
  end

  test "save cannot select another TOML file through request parameters", %{
    conn: conn,
    temp_dir: temp_dir,
    config_path: config_path
  } do
    other_path = Path.join(temp_dir, "other.toml")
    File.write!(other_path, "[gao_note]\nstorage_path = \"untouched\"\n")
    {:ok, view, _html} = live(conn, @settings_path)

    render_submit(view, "save", %{
      "gao_note" => %{"storage_path" => "new-notes", "config_path" => other_path},
      "config_path" => other_path
    })

    assert {:ok, config} = Toml.decode_file(config_path)
    assert config["gao_note"]["storage_path"] == "new-notes"
    assert File.read!(other_path) =~ "untouched"
  end

  test "an environment override explains why the TOML setting cannot be saved", %{
    conn: conn,
    config_path: config_path,
    original_config: original_config
  } do
    variable = "GSMLG_GAO_NOTE__STORAGE_PATH"
    previous = System.get_env(variable)
    System.put_env(variable, "environment-notes")

    on_exit(fn ->
      if previous,
        do: System.put_env(variable, previous),
        else: System.delete_env(variable)
    end)

    {:ok, view, _html} = live(conn, @settings_path)

    html =
      view
      |> form("#gao-note-settings-form", gao_note: %{storage_path: "new-notes"})
      |> render_submit()

    assert html =~ "Storage path is controlled by an environment variable."
    refute html =~ "GaoNote settings saved."
    assert File.read!(config_path) == original_config
    assert Application.get_env(:gsmlg_gao_note, :storage_path) == nil
  end

  defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
