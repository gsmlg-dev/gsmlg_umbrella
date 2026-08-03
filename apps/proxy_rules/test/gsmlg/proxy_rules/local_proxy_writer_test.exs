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

      assert :ok = LocalProxyWriter.write(path, "new.example\n")
      assert File.read!(path) == "new.example\n"
      assert temporary_files(tmp_dir) == []
    end

    @tag :tmp_dir
    test "creates the target when it does not exist", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "proxy-list.txt")

      refute File.exists?(path)
      assert :ok = LocalProxyWriter.write(path, "new.example\n")
      assert File.read!(path) == "new.example\n"
      assert temporary_files(tmp_dir) == []
    end
  end

  describe "write/3" do
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
                     File.write!(temporary, "partial")
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
    test "closes and cleans the temporary file when an operation raises", %{tmp_dir: tmp_dir} do
      path = existing_target(tmp_dir)
      parent = self()

      assert_raise RuntimeError, "write crashed", fn ->
        LocalProxyWriter.write(path, "new.example\n",
          write: fn _io, _content -> raise "write crashed" end,
          close: fn io ->
            send(parent, :close_called_after_raise)
            :file.close(io)
          end
        )
      end

      assert_received :close_called_after_raise
      refute_received :close_called_after_raise
      assert_original_and_clean(path, tmp_dir)
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
end
