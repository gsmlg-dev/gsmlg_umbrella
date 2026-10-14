defmodule GSMLG.Config.GaoNoteSettingsTest do
  use ExUnit.Case, async: false

  alias GSMLG.Config.{GaoNoteSettings, Loader}

  @moduletag :tmp_dir

  setup do
    application_env =
      for {app, key} <- [
            {:gsmlg_config, :loaded_config_path},
            {:gsmlg_config, :loaded_config},
            {:gsmlg_gao_note, :storage_path},
            {:gsmlg_gao_note, :compat_services}
          ],
          do: {app, key, Application.fetch_env(app, key)}

    system_env =
      for key <- ["GSMLG_CONFIG_PATH", "GSMLG_GAO_NOTE__STORAGE_PATH"],
          do: {key, System.get_env(key)}

    Enum.each(system_env, fn {key, _} -> System.delete_env(key) end)
    Application.delete_env(:gsmlg_config, :loaded_config_path)
    Application.delete_env(:gsmlg_gao_note, :storage_path)
    Application.put_env(:gsmlg_config, :loaded_config, %{other: %{untouched: true}})

    on_exit(fn ->
      Enum.each(application_env, fn
        {app, key, {:ok, value}} -> Application.put_env(app, key, value)
        {app, key, :error} -> Application.delete_env(app, key)
      end)

      Enum.each(system_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "current storage path returns runtime configuration or default" do
    assert GaoNoteSettings.storage_path() == "gaonote"
    Application.put_env(:gsmlg_gao_note, :storage_path, "custom")
    assert GaoNoteSettings.storage_path() == "custom"
  end

  test "loader remembers the absolute selected custom path only after validation succeeds", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "custom.toml")
    File.write!(path, "[gao_note]\nstorage_path = \"initial\"\n")
    assert {:ok, _} = Loader.load(config_path: Path.relative_to_cwd(path))
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == path

    invalid_path = Path.join(dir, "invalid.toml")
    File.write!(invalid_path, "[gao_note]\nstorage_path = \"../invalid\"\n")
    assert {:error, _} = Loader.load(config_path: invalid_path)
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == path
    assert {:error, _} = Loader.load(config_path: Path.join(dir, "missing.toml"))
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == path
  end

  test "loader tracks the actual environment file or fallback selection", %{tmp_dir: dir} do
    fallback = Path.join(dir, "gsmlg.toml")
    selected = Path.join(dir, "gsmlg.test.toml")
    File.rm(selected)
    File.write!(fallback, "[gao_note]\nstorage_path = \"fallback\"\n")
    assert {:ok, _} = Loader.load(env: :test, config_dir: dir)
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == fallback

    File.write!(selected, "[gao_note]\nstorage_path = \"test-file\"\n")
    assert {:ok, _} = Loader.load(env: :test, config_dir: dir)
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == selected
    assert {:ok, %{gao_note: %{storage_path: "test-file"}}} = Loader.load_config_file(:test, dir)
  end

  test "loader tracks the GSMLG_CONFIG_PATH selection", %{tmp_dir: dir} do
    path = Path.join(dir, "environment.toml")
    File.write!(path, "[gao_note]\nstorage_path = \"environment\"\n")
    System.put_env("GSMLG_CONFIG_PATH", path)
    assert {:ok, _} = Loader.load()
    assert Application.get_env(:gsmlg_config, :loaded_config_path) == path
  end

  test "runtime config carries the selected path into returned application configuration", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "runtime.toml")
    File.write!(path, "[gao_note]\nstorage_path = \"runtime\"\n")
    System.put_env("GSMLG_CONFIG_PATH", path)
    runtime = Path.expand("../../../../../config/runtime.exs", __DIR__)
    config = Config.Reader.read!(runtime, env: :test, target: :host)
    assert config[:gsmlg_config][:loaded_config_path] == path
  end

  test "saving changes only the selected setting and preserves comments and permissions", %{
    tmp_dir: dir
  } do
    text = """
    # Preserve this file.
    [gao_note] # settings
    search_url = "https://index/search"
    storage_path = 'old' # keep this comment

    [other]
    value = "unchanged"
    """

    path = select_file(dir, text)
    File.chmod!(path, 0o640)
    assert {:ok, %{uid: original_uid, gid: original_gid}} = File.stat(path)
    services = %{search_url: "https://runtime/search"}
    Application.put_env(:gsmlg_gao_note, :compat_services, services)

    assert {:ok, "new-notes"} = GaoNoteSettings.save_storage_path("new-notes")
    assert File.read!(path) == String.replace(text, "'old'", "\"new-notes\"")
    assert {:ok, %{mode: mode, uid: ^original_uid, gid: ^original_gid}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o640
    assert GaoNoteSettings.storage_path() == "new-notes"
    assert GSMLG.Config.get([:gao_note, :storage_path]) == "new-notes"
    assert GSMLG.Config.get([:other, :untouched]) == true
    assert Application.get_env(:gsmlg_gao_note, :compat_services) == services
    assert File.ls!(dir) == ["selected.toml"]
  end

  test "saving preserves the original file owner and group", %{tmp_dir: dir} do
    path = select_file(dir, "[gao_note]\nstorage_path = \"old\"\n")
    assert {:ok, %{gid: initial_gid}} = File.stat(path)
    {group_ids, 0} = System.cmd("id", ["-G"])

    group =
      group_ids
      |> String.split()
      |> Enum.map(&String.to_integer/1)
      |> Enum.find(initial_gid, &(&1 != initial_gid))

    File.chgrp!(path, group)
    assert {:ok, %{uid: uid, gid: gid}} = File.stat(path)

    assert {:ok, "new-notes"} = GaoNoteSettings.save_storage_path("new-notes")
    assert {:ok, %{uid: ^uid, gid: ^gid}} = File.stat(path)
  end

  test "saving inserts an absent setting in the GaoNote table", %{tmp_dir: dir} do
    path = select_file(dir, "[gao_note]\nsearch_url = \"\"\n[other]\nvalue = 2\n")
    assert {:ok, "new"} = GaoNoteSettings.save_storage_path("new")
    assert {:ok, config} = Toml.decode_file(path, keys: :atoms)
    assert config == %{gao_note: %{storage_path: "new", search_url: ""}, other: %{value: 2}}
  end

  test "saving adds an absent GaoNote section", %{tmp_dir: dir} do
    text = "# Existing config\n[other]\nvalue = 2"
    path = select_file(dir, text)
    assert {:ok, "new"} = GaoNoteSettings.save_storage_path("new")
    assert String.starts_with?(File.read!(path), text)
    assert {:ok, config} = Toml.decode_file(path, keys: :atoms)
    assert config == %{gao_note: %{storage_path: "new"}, other: %{value: 2}}
  end

  test "invalid input leaves file and runtime configuration unchanged", %{tmp_dir: dir} do
    text = "[gao_note]\nstorage_path = \"old\"\n"
    path = select_file(dir, text)

    for invalid <- ["", "a/b", "..", nil, 123] do
      assert {:error, _} = GaoNoteSettings.save_storage_path(invalid)
      assert File.read!(path) == text
      assert GaoNoteSettings.storage_path() == "old"
      assert GSMLG.Config.get([:gao_note, :storage_path]) == "old"
    end
  end

  test "an environment override prevents a misleading UI save", %{tmp_dir: dir} do
    text = "[gao_note]\nstorage_path = \"old\"\n"
    path = select_file(dir, text)
    System.put_env("GSMLG_GAO_NOTE__STORAGE_PATH", "environment")
    assert {:error, reason} = GaoNoteSettings.save_storage_path("new")
    assert inspect(reason) =~ "environment"
    assert File.read!(path) == text
    assert GaoNoteSettings.storage_path() == "old"
  end

  test "missing selected path and failed reads preserve runtime configuration", %{tmp_dir: dir} do
    assert {:error, _} = GaoNoteSettings.save_storage_path("new")
    Application.put_env(:gsmlg_gao_note, :storage_path, "old")
    Application.put_env(:gsmlg_config, :loaded_config_path, Path.join(dir, "missing.toml"))
    assert {:error, _} = GaoNoteSettings.save_storage_path("new")
    assert GaoNoteSettings.storage_path() == "old"
    assert GSMLG.Config.get([:other, :untouched]) == true
  end

  test "a failed write leaves the file and runtime untouched without temporary files", %{
    tmp_dir: dir
  } do
    text = "[gao_note]\nstorage_path = \"old\"\n"
    path = select_file(dir, text)
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod!(dir, 0o700) end)
    assert {:error, _} = GaoNoteSettings.save_storage_path("new")
    assert File.read!(path) == text
    assert GaoNoteSettings.storage_path() == "old"
    assert GSMLG.Config.get([:gao_note, :storage_path]) == "old"
    assert File.ls!(dir) == ["selected.toml"]
  end

  test "unsupported quoted or dotted GaoNote formats leave the file unchanged", %{tmp_dir: dir} do
    for text <- ["[\"gao_note\"]\nstorage_path = \"old\"\n", "gao_note.storage_path = \"old\"\n"] do
      path = select_file(dir, text)
      assert {:error, reason} = GaoNoteSettings.save_storage_path("new")
      assert inspect(reason) =~ "unsupported"
      assert File.read!(path) == text
      assert GaoNoteSettings.storage_path() == "old"
    end
  end

  test "roundtrip verification rejects a header-like line inside a multiline string", %{
    tmp_dir: dir
  } do
    text = "[other]\nvalue = \"\"\"\n[gao_note]\nstorage_path = 'fake'\n\"\"\"\n"
    path = select_file(dir, text)
    assert {:error, _} = GaoNoteSettings.save_storage_path("new")
    assert File.read!(path) == text
    assert GaoNoteSettings.storage_path() == "old"
  end

  defp select_file(dir, text) do
    path = Path.join(dir, "selected.toml")
    File.write!(path, text)
    Application.put_env(:gsmlg_config, :loaded_config_path, path)

    Application.put_env(:gsmlg_config, :loaded_config, %{
      gao_note: %{storage_path: "old"},
      other: %{untouched: true}
    })

    Application.put_env(:gsmlg_gao_note, :storage_path, "old")
    path
  end
end
