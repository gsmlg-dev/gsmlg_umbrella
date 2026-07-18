defmodule GSMLG.AdminWeb.GaoNoteAttachmentTempTest do
  use ExUnit.Case, async: false

  alias GSMLG.AdminWeb.GaoNoteAttachmentTemp

  test "creates a private service-owned root, editor, and exclusive stage files" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    source_path = unique_temp_path("source")
    File.write!(source_path, "first")

    on_exit(fn ->
      GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
      File.rm(source_path)
    end)

    assert {:ok, first_path, 5} =
             GaoNoteAttachmentTemp.copy_upload(editor_dir, source_path)

    File.write!(source_path, "second")

    assert {:ok, second_path, 6} =
             GaoNoteAttachmentTemp.copy_upload(editor_dir, source_path)

    assert first_path != second_path
    assert File.read!(first_path) == "first"
    assert File.read!(second_path) == "second"

    assert {:ok, uid} = GaoNoteAttachmentTemp.service_uid()
    assert {:ok, root_stat} = File.lstat(GaoNoteAttachmentTemp.root_path(), time: :posix)
    assert {:ok, editor_stat} = File.lstat(editor_dir, time: :posix)
    assert {:ok, first_stat} = File.lstat(first_path, time: :posix)

    assert root_stat.type == :directory
    assert editor_stat.type == :directory
    assert first_stat.type == :regular
    assert root_stat.uid == uid
    assert editor_stat.uid == uid
    assert first_stat.uid == uid
    assert private_mode(root_stat) == 0o700
    assert private_mode(editor_stat) == 0o700
    assert private_mode(first_stat) == 0o600
  end

  test "accepts a pre-created valid private editor directory" do
    bootstrap_dir = GaoNoteAttachmentTemp.new_editor_dir()
    assert {:ok, _path, 0} = GaoNoteAttachmentTemp.create_empty(bootstrap_dir)
    GaoNoteAttachmentTemp.cleanup_editor(bootstrap_dir)

    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    File.mkdir!(editor_dir)
    File.chmod!(editor_dir, 0o700)
    on_exit(fn -> GaoNoteAttachmentTemp.cleanup_editor(editor_dir) end)

    assert {:ok, staged_path, 0} = GaoNoteAttachmentTemp.create_empty(editor_dir)
    assert GaoNoteAttachmentTemp.regular_file?(editor_dir, staged_path)
  end

  test "rejects pre-existing root and editor directories with group or other permissions" do
    bootstrap_dir = GaoNoteAttachmentTemp.new_editor_dir()
    assert {:ok, _path, 0} = GaoNoteAttachmentTemp.create_empty(bootstrap_dir)
    GaoNoteAttachmentTemp.cleanup_editor(bootstrap_dir)

    root = GaoNoteAttachmentTemp.root_path()
    unsafe_root_editor = GaoNoteAttachmentTemp.new_editor_dir()

    try do
      File.chmod!(root, 0o750)
      assert {:error, :unsafe_directory} = GaoNoteAttachmentTemp.create_empty(unsafe_root_editor)
    after
      File.chmod!(root, 0o700)
    end

    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    File.mkdir!(editor_dir)
    File.chmod!(editor_dir, 0o750)

    try do
      assert {:error, :unsafe_directory} = GaoNoteAttachmentTemp.create_empty(editor_dir)
    after
      File.chmod!(editor_dir, 0o700)
      GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
    end
  end

  test "rejects a pre-existing editor owned by another service user when chown is available" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    assert {:ok, staged_path, 0} = GaoNoteAttachmentTemp.create_empty(editor_dir)
    GaoNoteAttachmentTemp.cleanup_file(editor_dir, staged_path)
    assert {:ok, uid} = GaoNoteAttachmentTemp.service_uid()

    case File.chown(editor_dir, uid + 1) do
      :ok ->
        try do
          assert {:error, :unsafe_directory} = GaoNoteAttachmentTemp.create_empty(editor_dir)
        after
          :ok = File.chown(editor_dir, uid)
          GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
        end

      {:error, reason} ->
        assert reason in [:eperm, :enotsup, :einval]
        GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
    end
  end

  test "rejects an editor symlink swap and never writes through it" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    assert {:ok, _staged_path, 0} = GaoNoteAttachmentTemp.create_empty(editor_dir)
    GaoNoteAttachmentTemp.cleanup_editor(editor_dir)

    outside_dir = unique_temp_path("outside")
    File.mkdir!(outside_dir)
    File.chmod!(outside_dir, 0o700)
    File.ln_s!(outside_dir, editor_dir)

    on_exit(fn ->
      File.rm(editor_dir)
      File.rmdir(outside_dir)
    end)

    assert {:error, :unsafe_directory} = GaoNoteAttachmentTemp.create_empty(editor_dir)
    assert File.ls!(outside_dir) == []
  end

  test "never accepts or removes a staged path outside its exact editor directory" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    assert {:ok, _staged_path, 0} = GaoNoteAttachmentTemp.create_empty(editor_dir)

    outside_path = unique_temp_path("outside-file")
    File.write!(outside_path, "keep")

    on_exit(fn ->
      GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
      File.rm(outside_path)
    end)

    refute GaoNoteAttachmentTemp.regular_file?(editor_dir, outside_path)
    assert :ok = GaoNoteAttachmentTemp.cleanup_file(editor_dir, outside_path)
    assert File.read!(outside_path) == "keep"
  end

  test "sweeps only stale inactive private editors and never follows symlinks" do
    stale_dir = GaoNoteAttachmentTemp.new_editor_dir()
    recent_dir = GaoNoteAttachmentTemp.new_editor_dir()
    active_dir = GaoNoteAttachmentTemp.new_editor_dir()

    stale_owner = stage_from_owner(stale_dir, false)
    recent_owner = stage_from_owner(recent_dir, false)
    active_owner = stage_from_owner(active_dir, true)

    assert_receive {:owner_staged, ^stale_owner, ^stale_dir, {:ok, _, 0}}
    assert_receive {:owner_staged, ^recent_owner, ^recent_dir, {:ok, _, 0}}
    assert_receive {:owner_staged, ^active_owner, ^active_dir, {:ok, _, 0}}

    stale_owner_ref = Process.monitor(stale_owner)
    recent_owner_ref = Process.monitor(recent_owner)
    send(stale_owner, :release)
    send(recent_owner, :release)

    assert_receive {:DOWN, ^stale_owner_ref, :process, ^stale_owner, :normal}
    assert_receive {:DOWN, ^recent_owner_ref, :process, ^recent_owner, :normal}

    old_time =
      DateTime.utc_now()
      |> DateTime.add(-GaoNoteAttachmentTemp.stale_after_seconds() - 24 * 60 * 60)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_erl()

    File.touch!(stale_dir, old_time)
    File.touch!(active_dir, old_time)

    outside_dir = unique_temp_path("sweep-outside")
    File.mkdir!(outside_dir)
    symlink = Path.join(GaoNoteAttachmentTemp.root_path(), "editor-link-" <> token())
    File.ln_s!(outside_dir, symlink)

    on_exit(fn ->
      if Process.alive?(active_owner), do: send(active_owner, :stop)
      GaoNoteAttachmentTemp.cleanup_editor(stale_dir)
      GaoNoteAttachmentTemp.cleanup_editor(recent_dir)
      GaoNoteAttachmentTemp.cleanup_editor(active_dir)
      File.rm(symlink)
      File.rmdir(outside_dir)
    end)

    GaoNoteAttachmentTemp.sweep_stale()

    refute File.exists?(stale_dir)
    assert File.dir?(recent_dir)
    assert File.dir?(active_dir)
    assert File.dir?(outside_dir)
    assert File.lstat!(symlink).type == :symlink
  end

  test "owner death monitor cleans only its exact editor directory" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    other_dir = GaoNoteAttachmentTemp.new_editor_dir()
    owner = stage_two_from_owner(editor_dir, other_dir)

    assert_receive {:owner_staged_two, ^owner, {:ok, _, 0}, {:ok, other_path, 0}}
    owner_ref = Process.monitor(owner)
    assert {:ok, _monitor} = GaoNoteAttachmentTemp.monitor_owner(owner, editor_dir)

    send(owner, :release)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}

    assert_eventually(fn -> not File.exists?(editor_dir) end)
    assert File.dir?(other_dir)
    assert File.read!(other_path) == ""

    GaoNoteAttachmentTemp.cleanup_editor(other_dir)
  end

  test "owner monitor is idempotent with explicit cleanup" do
    editor_dir = GaoNoteAttachmentTemp.new_editor_dir()
    owner = stage_from_owner(editor_dir, true)

    assert_receive {:owner_staged, ^owner, ^editor_dir, {:ok, _, 0}}
    assert {:ok, _monitor} = GaoNoteAttachmentTemp.monitor_owner(owner, editor_dir)

    assert :ok = GaoNoteAttachmentTemp.cleanup_editor(editor_dir)
    refute File.exists?(editor_dir)

    owner_ref = Process.monitor(owner)
    send(owner, :stop)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    assert_eventually(fn -> not File.exists?(editor_dir) end)
  end

  defp stage_from_owner(editor_dir, hold?) do
    parent = self()

    spawn(fn ->
      result = GaoNoteAttachmentTemp.create_empty(editor_dir)
      send(parent, {:owner_staged, self(), editor_dir, result})

      if hold? do
        receive do
          :stop -> :ok
        end
      else
        receive do
          :release -> :ok
        end
      end
    end)
  end

  defp stage_two_from_owner(editor_dir, other_dir) do
    parent = self()

    spawn(fn ->
      first = GaoNoteAttachmentTemp.create_empty(editor_dir)
      second = GaoNoteAttachmentTemp.create_empty(other_dir)
      send(parent, {:owner_staged_two, self(), first, second})

      receive do
        message when message in [:release, :stop] -> :ok
      end
    end)
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(fun, 0), do: assert(fun.())

  defp private_mode(stat), do: Bitwise.band(stat.mode, 0o777)

  defp unique_temp_path(prefix),
    do: Path.join(System.tmp_dir!(), "gao-note-#{prefix}-#{token()}")

  defp token do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
