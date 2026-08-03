defmodule GSMLG.ProxyRules.LocalProxyWriter do
  @moduledoc """
  Atomically replaces the local proxy source with synced content.

  Content is written to an exclusive temporary file in the target directory,
  synced, closed, and then renamed over the target.
  """

  @type error_reason ::
          :permission_denied
          | :open_failed
          | :write_failed
          | :sync_failed
          | :close_failed
          | :rename_failed

  @doc "Atomically replaces `path` with `content`."
  @spec write(binary(), binary()) :: :ok | {:error, error_reason()}
  def write(path, content), do: write(path, content, [])

  @doc false
  @spec write(binary(), binary(), keyword()) :: :ok | {:error, error_reason()}
  def write(path, content, overrides) when is_binary(path) and is_binary(content) do
    temporary = temporary_path(path)
    open = Keyword.get(overrides, :open, &:file.open(&1, [:write, :binary, :raw, :exclusive]))
    write = Keyword.get(overrides, :write, &:file.write/2)
    sync = Keyword.get(overrides, :sync, &:file.sync/1)
    close = Keyword.get(overrides, :close, &:file.close/1)
    rename = Keyword.get(overrides, :rename, &File.rename/2)
    remove = Keyword.get(overrides, :remove, &File.rm/1)

    try do
      with {:ok, io} <- open_result(open.(String.to_charlist(temporary))),
           :ok <- write_and_close(io, content, write, sync, close),
           :ok <- operation_result(:rename, rename.(temporary, path)) do
        :ok
      end
    after
      _ = remove.(temporary)
    end
  end

  defp write_and_close(io, content, write, sync, close) do
    close_failure = make_ref()

    try do
      try do
        with :ok <- operation_result(:write, write.(io, content)),
             :ok <- operation_result(:sync, sync.(io)) do
          :ok
        end
      after
        case operation_result(:close, close.(io)) do
          :ok -> :ok
          failure -> throw({close_failure, failure})
        end
      end
    catch
      :throw, {^close_failure, failure} -> failure
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
  defp stage_failure(:rename, _reason), do: {:error, :rename_failed}

  defp temporary_path(path) do
    basename = Path.basename(path)
    unique = System.unique_integer([:positive, :monotonic])

    Path.join(Path.dirname(path), ".#{basename}.tmp-#{unique}")
  end
end
