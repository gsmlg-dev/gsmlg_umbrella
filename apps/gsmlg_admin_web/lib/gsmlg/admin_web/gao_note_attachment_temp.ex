defmodule GSMLG.AdminWeb.GaoNoteAttachmentTemp do
  @moduledoc false

  @root_name "gsmlg-admin-gao-note-attachments"
  @editor_prefix "editor-"
  @stage_prefix "stage-"
  @owner_file ".owner"
  @stale_after_seconds 7 * 24 * 60 * 60
  @copy_chunk_size 64 * 1024

  def root_path, do: Path.join(System.tmp_dir!(), @root_name)
  def stale_after_seconds, do: @stale_after_seconds

  def new_editor_dir do
    Path.join(root_path(), @editor_prefix <> random_token())
  end

  def monitor_owner(owner_pid, editor_dir) when is_pid(owner_pid) do
    if valid_editor_path?(editor_dir) do
      caller = self()
      ready_reference = make_ref()

      case Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
             owner_reference = Process.monitor(owner_pid)
             send(caller, {ready_reference, self()})

             receive do
               {:DOWN, ^owner_reference, :process, ^owner_pid, _reason} ->
                 cleanup_editor_for_owner(editor_dir, owner_pid)
             end
           end) do
        {:ok, monitor_pid} = result ->
          receive do
            {^ready_reference, ^monitor_pid} -> result
          after
            1_000 ->
              Process.exit(monitor_pid, :kill)
              {:error, :monitor_start_timeout}
          end

        {:error, _reason} = error ->
          error
      end
    else
      {:error, :unsafe_editor_path}
    end
  end

  def copy_upload(editor_dir, source_path) when is_binary(source_path) do
    with {:ok, staged_path, destination, uid} <- open_exclusive_stage(editor_dir) do
      copy_result = copy_source(source_path, destination, editor_dir, uid)
      close_result = File.close(destination)

      case {copy_result, close_result, private_stage_stat(staged_path, editor_dir, uid)} do
        {:ok, :ok, {:ok, stat}} ->
          {:ok, staged_path, stat.size}

        {{:error, reason}, _, _} ->
          cleanup_file(editor_dir, staged_path)
          {:error, reason}

        {_, {:error, reason}, _} ->
          cleanup_file(editor_dir, staged_path)
          {:error, reason}

        {_, _, {:error, reason}} ->
          cleanup_file(editor_dir, staged_path)
          {:error, reason}
      end
    end
  end

  def create_empty(editor_dir) do
    with {:ok, staged_path, destination, uid} <- open_exclusive_stage(editor_dir) do
      close_result = File.close(destination)

      case {close_result, private_stage_stat(staged_path, editor_dir, uid)} do
        {:ok, {:ok, stat}} ->
          {:ok, staged_path, stat.size}

        {{:error, reason}, _} ->
          cleanup_file(editor_dir, staged_path)
          {:error, reason}

        {_, {:error, reason}} ->
          cleanup_file(editor_dir, staged_path)
          {:error, reason}
      end
    end
  end

  def regular_file?(editor_dir, path) when is_binary(editor_dir) and is_binary(path) do
    with true <- valid_stage_path?(path),
         true <- Path.dirname(path) == editor_dir,
         {:ok, uid} <- service_uid(),
         :ok <- validate_existing_directory(root_path(), uid),
         :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, _stat} <- private_stage_stat(path, editor_dir, uid) do
      true
    else
      _invalid -> false
    end
  end

  def regular_file?(_editor_dir, _path), do: false

  def cleanup_file(editor_dir, path) when is_binary(editor_dir) and is_binary(path) do
    with true <- valid_stage_path?(path),
         true <- Path.dirname(path) == editor_dir,
         {:ok, uid} <- service_uid(),
         :ok <- validate_existing_directory(root_path(), uid),
         :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type in [:regular, :symlink] do
      File.rm(path)
    else
      _invalid_or_absent -> :ok
    end
  end

  def cleanup_file(_editor_dir, _path), do: :ok

  def cleanup_editor(editor_dir) do
    with true <- valid_editor_path?(editor_dir),
         {:ok, uid} <- service_uid(),
         :ok <- validate_existing_directory(root_path(), uid),
         :ok <- validate_existing_directory(editor_dir, uid) do
      remove_tree(editor_dir)
    else
      _invalid_or_absent -> :ok
    end
  end

  def cleanup_editor_for_owner(editor_dir, owner_pid) when is_pid(owner_pid) do
    with true <- valid_editor_path?(editor_dir),
         {:ok, uid} <- service_uid(),
         :ok <- validate_existing_directory(root_path(), uid),
         :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, {owner_node, ^owner_pid}} <- read_owner(editor_dir, uid),
         true <- owner_node == node() do
      remove_tree(editor_dir)
    else
      _invalid_or_absent -> :ok
    end
  end

  def sweep_stale do
    with {:ok, uid} <- service_uid(),
         :ok <- validate_existing_directory(root_path(), uid),
         {:ok, entries} <- File.ls(root_path()) do
      Enum.each(entries, &sweep_entry(&1, uid))
    else
      {:error, :enoent} -> :ok
      _unsafe_or_absent -> :ok
    end
  end

  def service_uid do
    probe_path = Path.join(System.tmp_dir!(), ".gsmlg-gao-note-uid-" <> random_token())

    case File.open(probe_path, [:write, :binary, :exclusive]) do
      {:ok, probe} ->
        try do
          with :ok <- File.chmod(probe_path, 0o600),
               {:ok, stat} <- File.lstat(probe_path, time: :posix) do
            {:ok, stat.uid}
          end
        after
          _ = File.close(probe)
          _ = File.rm(probe_path)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_exclusive_stage(editor_dir) do
    with {:ok, uid} <- ensure_editor_dir(editor_dir),
         :ok <- validate_existing_directory(editor_dir, uid) do
      staged_path = Path.join(editor_dir, @stage_prefix <> random_token())

      case File.open(staged_path, [:write, :binary, :exclusive]) do
        {:ok, destination} ->
          case secure_open_stage(staged_path, editor_dir, destination, uid) do
            :ok ->
              {:ok, staged_path, destination, uid}

            {:error, reason} ->
              _ = File.close(destination)
              _ = File.rm(staged_path)
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp secure_open_stage(staged_path, editor_dir, destination, uid) do
    with :ok <- File.chmod(staged_path, 0o600),
         :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, _stat} <- private_stage_stat(staged_path, editor_dir, uid) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :unsafe_stage_file}
    end
  end

  defp copy_source(source_path, destination, editor_dir, uid) do
    case File.open(source_path, [:read, :binary], fn source ->
           copy_chunks(source, destination, editor_dir, uid)
         end) do
      :ok -> :ok
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_chunks(source, destination, editor_dir, uid) do
    case IO.binread(source, @copy_chunk_size) do
      :eof ->
        :ok

      {:error, reason} ->
        {:error, reason}

      bytes when is_binary(bytes) ->
        with :ok <- validate_existing_directory(editor_dir, uid),
             :ok <- IO.binwrite(destination, bytes) do
          copy_chunks(source, destination, editor_dir, uid)
        end
    end
  end

  defp private_stage_stat(path, editor_dir, uid) do
    with :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :regular,
         true <- stat.uid == uid,
         true <- private_mode?(stat.mode, 0o600) do
      {:ok, stat}
    else
      {:error, reason} -> {:error, reason}
      _unsafe -> {:error, :unsafe_stage_file}
    end
  end

  defp ensure_editor_dir(editor_dir) do
    with true <- valid_editor_path?(editor_dir),
         {:ok, uid} <- service_uid(),
         :ok <- ensure_private_directory(root_path(), uid),
         :ok <- ensure_private_directory(editor_dir, uid),
         :ok <- ensure_owner(editor_dir, uid) do
      {:ok, uid}
    else
      false -> {:error, :unsafe_editor_path}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_private_directory(path, uid) do
    case File.lstat(path, time: :posix) do
      {:ok, _stat} ->
        validate_existing_directory(path, uid)

      {:error, :enoent} ->
        case File.mkdir(path) do
          :ok ->
            with :ok <- File.chmod(path, 0o700) do
              validate_existing_directory(path, uid)
            end

          {:error, :eexist} ->
            validate_existing_directory(path, uid)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_existing_directory(path, uid) do
    with {:ok, stat} <- File.lstat(path, time: :posix),
         true <- stat.type == :directory,
         true <- stat.uid == uid,
         true <- private_mode?(stat.mode, 0o700) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _unsafe -> {:error, :unsafe_directory}
    end
  end

  defp ensure_owner(editor_dir, uid) do
    owner_path = Path.join(editor_dir, @owner_file)

    case File.lstat(owner_path, time: :posix) do
      {:ok, _stat} ->
        with {:ok, {owner_node, owner_pid}} <- read_owner(editor_dir, uid),
             true <- owner_node == node() and owner_pid == self() do
          :ok
        else
          _unsafe -> {:error, :unsafe_owner}
        end

      {:error, :enoent} ->
        write_owner(editor_dir, owner_path, uid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_owner(editor_dir, owner_path, uid) do
    with :ok <- validate_existing_directory(editor_dir, uid) do
      case File.open(owner_path, [:write, :binary, :exclusive]) do
        {:ok, owner_file} ->
          result =
            with :ok <- File.chmod(owner_path, 0o600),
                 :ok <- validate_existing_directory(editor_dir, uid),
                 :ok <- IO.binwrite(owner_file, :erlang.term_to_binary({node(), self()})),
                 :ok <- File.close(owner_file),
                 {:ok, _owner} <- read_owner(editor_dir, uid) do
              :ok
            else
              {:error, reason} -> {:error, reason}
              _unsafe -> {:error, :unsafe_owner}
            end

          if result != :ok do
            _ = File.close(owner_file)
            _ = File.rm(owner_path)
          end

          result

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp read_owner(editor_dir, uid) do
    owner_path = Path.join(editor_dir, @owner_file)

    with :ok <- validate_existing_directory(editor_dir, uid),
         {:ok, stat} <- File.lstat(owner_path, time: :posix),
         true <- stat.type == :regular,
         true <- stat.uid == uid,
         true <- private_mode?(stat.mode, 0o600),
         {:ok, binary} <- File.read(owner_path) do
      case :erlang.binary_to_term(binary, [:safe]) do
        {owner_node, owner_pid} when is_atom(owner_node) and is_pid(owner_pid) ->
          {:ok, {owner_node, owner_pid}}

        _invalid ->
          {:error, :unsafe_owner}
      end
    else
      {:error, reason} -> {:error, reason}
      _unsafe -> {:error, :unsafe_owner}
    end
  rescue
    ArgumentError -> {:error, :unsafe_owner}
  end

  defp sweep_entry(entry, uid) do
    editor_dir = Path.join(root_path(), entry)

    if String.starts_with?(entry, @editor_prefix) and valid_editor_path?(editor_dir) do
      with :ok <- validate_existing_directory(editor_dir, uid),
           {:ok, stat} <- File.lstat(editor_dir, time: :posix),
           true <- stale?(stat),
           false <- active_owner?(editor_dir, uid) do
        remove_tree(editor_dir)
      else
        _recent_active_or_unsafe -> :ok
      end
    end
  end

  defp active_owner?(editor_dir, uid) do
    case read_owner(editor_dir, uid) do
      {:ok, {owner_node, owner_pid}} when owner_node == node() ->
        Process.alive?(owner_pid)

      _missing_remote_or_invalid ->
        false
    end
  end

  defp stale?(stat) do
    System.system_time(:second) - stat.mtime >= @stale_after_seconds
  end

  defp remove_tree(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %{type: :directory}} ->
        with {:ok, entries} <- File.ls(path) do
          Enum.each(entries, &remove_tree(Path.join(path, &1)))
          File.rmdir(path)
        else
          _error -> :ok
        end

      {:ok, %{type: type}} when type in [:regular, :symlink] ->
        File.rm(path)

      _unsafe_or_absent ->
        :ok
    end
  end

  defp private_mode?(mode, expected), do: Bitwise.band(mode, 0o777) == expected

  defp valid_editor_path?(editor_dir) when is_binary(editor_dir) do
    Path.dirname(editor_dir) == root_path() and
      String.starts_with?(Path.basename(editor_dir), @editor_prefix)
  end

  defp valid_editor_path?(_editor_dir), do: false

  defp valid_stage_path?(path) when is_binary(path) do
    editor_dir = Path.dirname(path)

    valid_editor_path?(editor_dir) and
      String.starts_with?(Path.basename(path), @stage_prefix)
  end

  defp valid_stage_path?(_path), do: false

  defp random_token do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
