defmodule GSMLG.ProxyRules.LocalProxyWriter do
  @moduledoc """
  Atomically replaces the local proxy source with synced content.

  An exclusive temporary file is opened in the target directory, assigned its
  final mode, written, synced, closed, renamed over the target, and committed
  by syncing the parent directory. A target must be absent or a regular file;
  symlinks and other file types are rejected. Existing permission bits are
  preserved, while a new target is created with mode `0600`.

  `{:error, reason}` is returned only before rename and guarantees that the
  target is unchanged. If rename succeeds but syncing the parent directory
  fails, the committed bytes are reported as `{:ok, :durability_unknown}`.
  """

  @max_open_attempts 4

  @type error_reason ::
          :permission_denied
          | :open_failed
          | :write_failed
          | :sync_failed
          | :close_failed
          | :mode_failed
          | :rename_failed
          | :invalid_target
          | :target_probe_failed
  @type result :: :ok | {:ok, :durability_unknown} | {:error, error_reason()}

  @doc "Atomically replaces `path` with `content`, reporting post-rename durability uncertainty."
  @spec write(binary(), binary()) :: result()
  def write(path, content), do: write(path, content, [])

  @doc false
  @spec write(binary(), binary(), keyword()) :: result()
  def write(path, content, overrides) when is_binary(path) and is_binary(content) do
    operations = operations(overrides)

    with {:ok, mode} <- probe_target(fn -> operations.lstat.(path) end),
         {:ok, temporary, io} <- open_temporary(path, operations.open, @max_open_attempts) do
      write_owned(temporary, io, path, content, mode, operations)
    end
  end

  defp operations(overrides) do
    %{
      open: Keyword.get(overrides, :open, &:file.open(&1, [:write, :binary, :raw, :exclusive])),
      write: Keyword.get(overrides, :write, &:file.write/2),
      sync: Keyword.get(overrides, :sync, &:file.sync/1),
      close: Keyword.get(overrides, :close, &:file.close/1),
      chmod: Keyword.get(overrides, :chmod, &File.chmod/2),
      rename: Keyword.get(overrides, :rename, &File.rename/2),
      directory_sync: Keyword.get(overrides, :directory_sync, &sync_directory/1),
      remove: Keyword.get(overrides, :remove, &File.rm/1),
      lstat: Keyword.get(overrides, :lstat, &File.lstat/1)
    }
  end

  defp open_temporary(path, open, attempts_left) do
    temporary = temporary_path(path)

    case call_open(fn -> open.(String.to_charlist(temporary)) end) do
      {:ok, io} ->
        {:ok, temporary, io}

      {:error, :eexist} when attempts_left > 1 ->
        open_temporary(path, open, attempts_left - 1)

      result ->
        open_result(result)
    end
  end

  defp write_owned(temporary, io, path, content, mode, operations) do
    try do
      with :ok <-
             prepare_file(temporary, io, content, mode, operations),
           :ok <- call_operation(:rename, fn -> operations.rename.(temporary, path) end) do
        commit_directory_sync(fn -> operations.directory_sync.(Path.dirname(path)) end)
      end
    after
      safely_remove(fn -> operations.remove.(temporary) end)
    end
  end

  defp prepare_file(temporary, io, content, mode, operations) do
    case call_operation(:mode, fn -> operations.chmod.(temporary, mode) end) do
      :ok ->
        write_and_close(io, content, operations.write, operations.sync, operations.close)

      failure ->
        _ = call_operation(:close, fn -> operations.close.(io) end)
        failure
    end
  end

  defp write_and_close(io, content, write, sync, close) do
    primary_result =
      case call_operation(:write, fn -> write.(io, content) end) do
        :ok -> call_operation(:sync, fn -> sync.(io) end)
        failure -> failure
      end

    close_result = call_operation(:close, fn -> close.(io) end)

    case primary_result do
      :ok -> close_result
      failure -> failure
    end
  end

  defp call_operation(stage, operation) do
    try do
      operation_result(stage, operation.())
    rescue
      _error -> stage_failure(stage, :exception)
    catch
      _kind, _reason -> stage_failure(stage, :exception)
    end
  end

  defp commit_directory_sync(operation) do
    try do
      case operation.() do
        :ok -> :ok
        _failure -> {:ok, :durability_unknown}
      end
    rescue
      _error -> {:ok, :durability_unknown}
    catch
      _kind, _reason -> {:ok, :durability_unknown}
    end
  end

  defp call_open(operation) do
    try do
      operation.()
    rescue
      _error -> {:error, :open_failed}
    catch
      _kind, _reason -> {:error, :open_failed}
    end
  end

  defp probe_target(operation) do
    try do
      target_mode(operation.())
    rescue
      _error -> {:error, :target_probe_failed}
    catch
      _kind, _reason -> {:error, :target_probe_failed}
    end
  end

  defp safely_remove(operation) do
    try do
      _ = operation.()
      :ok
    rescue
      _error -> :ok
    catch
      _kind, _reason -> :ok
    end
  end

  defp open_result({:ok, io}), do: {:ok, io}
  defp open_result({:error, reason}), do: stage_failure(:open, reason)
  defp open_result(_other), do: {:error, :open_failed}

  defp operation_result(_stage, :ok), do: :ok
  defp operation_result(stage, {:error, reason}), do: stage_failure(stage, reason)
  defp operation_result(stage, _other), do: stage_failure(stage, :unexpected_result)

  defp stage_failure(_stage, reason) when reason in [:eacces, :eperm],
    do: {:error, :permission_denied}

  defp stage_failure(:open, _reason), do: {:error, :open_failed}
  defp stage_failure(:write, _reason), do: {:error, :write_failed}
  defp stage_failure(:sync, _reason), do: {:error, :sync_failed}
  defp stage_failure(:close, _reason), do: {:error, :close_failed}
  defp stage_failure(:mode, _reason), do: {:error, :mode_failed}
  defp stage_failure(:rename, _reason), do: {:error, :rename_failed}

  defp target_mode({:ok, %File.Stat{type: :regular, mode: mode}}),
    do: {:ok, Bitwise.band(mode, 0o7777)}

  defp target_mode({:ok, %File.Stat{}}), do: {:error, :invalid_target}
  defp target_mode({:error, :enoent}), do: {:ok, 0o600}

  defp target_mode({:error, reason}) when reason in [:eacces, :eperm],
    do: {:error, :permission_denied}

  defp target_mode({:error, _reason}), do: {:error, :target_probe_failed}
  defp target_mode(_other), do: {:error, :target_probe_failed}

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, io} ->
        try do
          :file.sync(io)
        after
          _ = :file.close(io)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(path) do
    basename = Path.basename(path)
    unique = :crypto.strong_rand_bytes(16) |> :binary.decode_unsigned() |> max(1)

    Path.join(Path.dirname(path), ".#{basename}.tmp-#{unique}")
  end
end
