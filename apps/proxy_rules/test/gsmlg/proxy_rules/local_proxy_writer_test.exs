defmodule GSMLG.ProxyRules.LocalProxyWriterTest do
  use ExUnit.Case, async: true

  alias GSMLG.ProxyRules.LocalProxyWriter

  describe "write/2" do
    @tag :tmp_dir
    test "atomically replaces an existing target and removes the temporary file", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "proxy-list.txt")
      File.write!(path, "old.example\n")
      File.chmod!(path, 0o640)

      assert :ok = LocalProxyWriter.write(path, "new.example\n")
      assert File.read!(path) == "new.example\n"
      assert file_mode(path) == 0o640
      assert temporary_files(tmp_dir) == []
    end

    @tag :tmp_dir
    test "creates the target when it does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "proxy-list.txt")

      refute File.exists?(path)
      assert :ok = LocalProxyWriter.write(path, "new.example\n")
      assert File.read!(path) == "new.example\n"
      assert file_mode(path) == 0o600
      assert temporary_files(tmp_dir) == []
    end
  end

  describe "write/3" do
    @tag :tmp_dir
    test "applies the target mode before writing temporary content", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      File.chmod!(path, 0o640)
      parent = self()

      assert :ok =
               LocalProxyWriter.write(path, "new.example\n",
                 open: fn temporary ->
                   send(parent, {:temporary_opened, List.to_string(temporary)})
                   :file.open(temporary, [:write, :binary, :raw, :exclusive])
                 end,
                 write: fn io, content ->
                   assert_received {:temporary_opened, temporary}
                   send(parent, {:mode_during_write, file_mode(temporary)})
                   :file.write(io, content)
                 end
               )

      assert_received {:mode_during_write, 0o640}
      assert File.read!(path) == "new.example\n"
      assert file_mode(path) == 0o640
    end

    @tag :tmp_dir
    test "bounds a pre-write mode failure and cleans the owned temporary file", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :mode_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 chmod: fn temporary, _mode ->
                   send(parent, {:mode_failed_for, temporary})
                   {:error, :eio}
                 end,
                 write: fn _io, _content ->
                   send(parent, :write_called_after_mode_failure)
                   :ok
                 end,
                 close: fn io ->
                   send(parent, :close_after_mode_failure)
                   :file.close(io)
                 end
               )

      assert_received {:mode_failed_for, temporary}
      assert_received :close_after_mode_failure
      refute_received :write_called_after_mode_failure
      refute File.exists?(temporary)
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "maps only access errors to permission denied and cleans partial open output", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)
      parent = self()

      for reason <- [:eacces, :eperm] do
        assert {:error, :permission_denied} =
                 LocalProxyWriter.write(path, "new.example\n",
                   open: fn temporary ->
                     temporary = List.to_string(temporary)
                     send(parent, {:temporary, temporary})
                     {:error, reason}
                   end
                 )

        assert_received {:temporary, temporary}
        assert Path.dirname(temporary) == tmp_dir
        assert Path.basename(temporary) =~ ~r/^\.proxy-list\.txt\.tmp-[1-9][0-9]*$/
        assert_original_and_clean(path, tmp_dir)
      end

      assert {:error, :open_failed} =
               LocalProxyWriter.write(path, "new.example\n", open: fn _ -> {:error, :eio} end)

      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "retries an exclusive-open collision without removing the colliding file", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)
      attempts = :atomics.new(1, signed: false)
      parent = self()

      open = fn temporary ->
        temporary_path = List.to_string(temporary)
        attempt = :atomics.add_get(attempts, 1, 1)
        send(parent, {:open_attempt, attempt, temporary_path})

        if attempt == 1 do
          File.write!(temporary_path, "collision sentinel")
          {:error, :eexist}
        else
          :file.open(temporary, [:write, :binary, :raw, :exclusive])
        end
      end

      assert :ok = LocalProxyWriter.write(path, "new.example\n", open: open)
      assert_received {:open_attempt, 1, collision}
      assert_received {:open_attempt, 2, owned}
      refute collision == owned
      assert File.read!(collision) == "collision sentinel"
      refute File.exists?(owned)
      assert File.read!(path) == "new.example\n"
    end

    @tag :tmp_dir
    test "bounds exclusive-open collision retries and preserves every collision", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)
      attempts = :atomics.new(1, signed: false)
      parent = self()

      open = fn temporary ->
        temporary_path = List.to_string(temporary)
        attempt = :atomics.add_get(attempts, 1, 1)
        File.write!(temporary_path, "collision #{attempt}")
        send(parent, {:collision, attempt, temporary_path})
        {:error, :eexist}
      end

      assert {:error, :open_failed} =
               LocalProxyWriter.write(path, "new.example\n", open: open)

      assert_received {:collision, 1, first}
      assert_received {:collision, 2, second}
      assert_received {:collision, 3, third}
      assert_received {:collision, 4, fourth}
      refute_received {:collision, 5, _path}

      for {collision, attempt} <- Enum.with_index([first, second, third, fourth], 1) do
        assert File.read!(collision) == "collision #{attempt}"
      end

      assert File.read!(path) == "old.example\n"
    end

    @tag :tmp_dir
    test "preserves the target and cleans the temporary file after a write failure", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)

      assert {:error, :write_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 write: fn _io, _content -> {:error, :eio} end
               )

      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "preserves the target and cleans the temporary file after a sync failure", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)

      assert {:error, :sync_failed} =
               LocalProxyWriter.write(path, "new.example\n", sync: fn _io -> {:error, :eio} end)

      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "preserves a primary write failure when close also fails", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :write_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 write: fn _io, _content -> {:error, :eio} end,
                 close: fn io ->
                   send(parent, :close_after_write_failure)
                   assert :ok = :file.close(io)
                   {:error, :eio}
                 end
               )

      assert_received :close_after_write_failure
      refute_received :close_after_write_failure
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "preserves a primary sync failure when close also fails", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :sync_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 sync: fn _io -> raise "sync crashed" end,
                 close: fn io ->
                   send(parent, :close_after_sync_failure)
                   assert :ok = :file.close(io)
                   {:error, :eio}
                 end
               )

      assert_received :close_after_sync_failure
      refute_received :close_after_sync_failure
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "closes exactly once and does not rename after a close failure", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :close_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 close: fn io ->
                   send(parent, :close_called)
                   assert :ok = :file.close(io)
                   {:error, :eio}
                 end,
                 remove: fn temporary ->
                   assert_received :close_called
                   send(parent, :remove_after_close)
                   File.rm(temporary)
                 end
               )

      assert_received :remove_after_close
      refute_received :close_called
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "preserves the target and cleans the temporary file after a rename failure", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)

      assert {:error, :rename_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 rename: fn _temporary, _target -> {:error, :exdev} end
               )

      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "syncs the parent directory after renaming the target", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert :ok =
               LocalProxyWriter.write(path, "new.example\n",
                 rename: fn temporary, target ->
                   assert :ok = File.rename(temporary, target)
                   send(parent, :rename_finished)
                   :ok
                 end,
                 directory_sync: fn directory ->
                   assert_received :rename_finished
                   send(parent, {:directory_synced, directory})
                   :ok
                 end
               )

      assert_received {:directory_synced, ^tmp_dir}
      assert File.read!(path) == "new.example\n"
      assert temporary_files(tmp_dir) == []
    end

    @tag :tmp_dir
    test "reports committed bytes with unknown durability when parent sync fails", %{
      tmp_dir: tmp_dir
    } do
      path = existing_target(tmp_dir)

      assert {:ok, :durability_unknown} =
               LocalProxyWriter.write(path, "new.example\n",
                 directory_sync: fn _directory -> {:error, :eio} end
               )

      assert File.read!(path) == "new.example\n"
      assert temporary_files(tmp_dir) == []

      assert {:ok, :durability_unknown} =
               LocalProxyWriter.write(path, "newer.example\n",
                 directory_sync: fn _directory -> raise "directory sync crashed" end
               )

      assert File.read!(path) == "newer.example\n"
      assert temporary_files(tmp_dir) == []
    end

    @tag :tmp_dir
    test "retains the primary failure when injected cleanup reports an error", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :rename_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 rename: fn _temporary, _target -> {:error, :exdev} end,
                 remove: fn temporary ->
                   send(parent, {:remove_called, temporary})
                   assert :ok = File.rm(temporary)
                   {:error, :eacces}
                 end
               )

      assert_received {:remove_called, temporary}
      assert Path.dirname(temporary) == tmp_dir
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "bounds operation exceptions while preserving the primary failure", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert {:error, :write_failed} =
               LocalProxyWriter.write(path, "new.example\n",
                 write: fn _io, _content -> raise "write crashed" end,
                 close: fn io ->
                   send(parent, :close_called_after_raise)
                   assert :ok = :file.close(io)
                   raise "close crashed"
                 end
               )

      assert_received :close_called_after_raise
      refute_received :close_called_after_raise
      assert_original_and_clean(path, tmp_dir)
    end

    @tag :tmp_dir
    test "rejects a symlink target without changing the link or its destination", %{
      tmp_dir: tmp_dir
    } do
      destination = Path.join(tmp_dir, "real-proxy-list.txt")
      path = Path.join(tmp_dir, "proxy-list.txt")
      File.write!(destination, "old.example\n")
      File.ln_s!(destination, path)

      assert {:error, :invalid_target} = LocalProxyWriter.write(path, "new.example\n")
      assert File.read_link!(path) == destination
      assert File.read!(destination) == "old.example\n"
      assert temporary_files(tmp_dir) == []
    end
  end

  defp existing_target(tmp_dir) do
    path = Path.join(tmp_dir, "proxy-list.txt")
    File.write!(path, "old.example\n")
    path
  end

  defp assert_original_and_clean(path, tmp_dir) do
    assert File.read!(path) == "old.example\n"
    assert temporary_files(tmp_dir) == []
  end

  defp temporary_files(tmp_dir),
    do: Path.wildcard(Path.join(tmp_dir, ".proxy-list.txt.tmp-*"))

  defp file_mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
