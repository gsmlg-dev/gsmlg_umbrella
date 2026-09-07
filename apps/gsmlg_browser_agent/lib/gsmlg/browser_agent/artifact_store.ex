defmodule GSMLG.BrowserAgent.ArtifactStore do
  @moduledoc "Durable local content store for remote-pending Browser artifacts."

  @required ~w(artifact_id kind mime filename metadata)
  @owners ~w(job_id session_id)
  @artifact_filename ~r/\A[A-Za-z0-9_-]{43}\z/
  @temporary_filename ~r/\A[A-Za-z0-9_-]{43}\.[0-9]+\.tmp\z/

  def prepare(state_dir, attrs, content, opts \\ [])

  def prepare(state_dir, attrs, content, opts) when is_map(attrs) and is_binary(content) do
    max_bytes = Keyword.get(opts, :max_bytes, 104_857_600)

    with :ok <- validate_attrs(attrs),
         :ok <- validate_size(content, max_bytes) do
      sha256 = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      manifest =
        attrs
        |> Map.take(@required ++ @owners)
        |> Map.merge(%{
          "protocol_version" => 1,
          "size" => byte_size(content),
          "sha256" => sha256,
          "transfer_mode" => "remote_pending"
        })

      {:ok, %{manifest: manifest, path: path(state_dir, attrs["artifact_id"])}}
    end
  end

  def prepare(_state_dir, _attrs, _content, _opts), do: {:error, :invalid_artifact}

  def commit(%{manifest: manifest, path: path}, content, opts \\ []) when is_binary(content) do
    directory_sync = Keyword.get(opts, :directory_sync, &sync_directory/1)

    with :ok <- validate_content(manifest, content),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      write_no_replace(path, content, directory_sync, opts)
    end
  end

  def read(%{manifest: manifest, path: path}) do
    with {:ok, content} <- File.read(path),
         :ok <- validate_content(manifest, content) do
      {:ok, content}
    end
  end

  def delete(%{path: path}, opts \\ []) do
    directory_sync = Keyword.get(opts, :directory_sync, &sync_directory/1)

    case File.rm(path) do
      :ok -> directory_sync.(Path.dirname(path))
      {:error, :enoent} -> sync_existing_directory(Path.dirname(path), directory_sync)
      {:error, reason} -> {:error, reason}
    end
  end

  def cleanup_untracked(state_dir, referenced_paths, opts \\ []) do
    directory = Path.join(state_dir, "artifacts")
    stale_after_ms = Keyword.get(opts, :stale_after_ms, 300_000)
    active_paths = Keyword.get(opts, :active_paths, [])

    case File.ls(directory) do
      {:ok, names} ->
        remove_untracked(
          directory,
          names,
          MapSet.new(referenced_paths),
          MapSet.new(active_paths),
          stale_after_ms,
          opts
        )

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def path(state_dir, artifact_id) do
    filename = :crypto.hash(:sha256, artifact_id) |> Base.url_encode64(padding: false)
    Path.join([state_dir, "artifacts", filename])
  end

  defp validate_attrs(attrs) do
    cond do
      Enum.sort(Map.keys(attrs)) not in [
        Enum.sort(@required ++ ["job_id"]),
        Enum.sort(@required ++ ["session_id"])
      ] ->
        {:error, :invalid_artifact}

      not Enum.all?(~w(artifact_id kind mime filename), fn key ->
        is_binary(attrs[key]) and attrs[key] != ""
      end) ->
        {:error, :invalid_artifact}

      not Enum.any?(@owners, fn key -> is_binary(attrs[key]) and attrs[key] != "" end) ->
        {:error, :invalid_artifact}

      not is_map(attrs["metadata"]) ->
        {:error, :invalid_artifact}

      true ->
        :ok
    end
  end

  defp validate_size(content, max_bytes)
       when is_integer(max_bytes) and max_bytes > 0 and byte_size(content) <= max_bytes,
       do: :ok

  defp validate_size(_content, _max_bytes), do: {:error, :artifact_too_large}

  defp validate_content(manifest, content) do
    cond do
      byte_size(content) != manifest["size"] -> {:error, :artifact_integrity_failed}
      secure_hash_match?(content, manifest["sha256"]) -> :ok
      true -> {:error, :artifact_integrity_failed}
    end
  end

  defp write_no_replace(path, content, directory_sync, opts) do
    temporary = path <> ".#{System.unique_integer([:positive])}.tmp"

    with {:ok, file} <-
           :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive]),
         :ok <- write_close(file, content),
         :ok <- before_link(opts) do
      link_temporary(temporary, path, directory_sync)
    else
      {:error, _reason} = error ->
        _ = File.rm(temporary)
        error
    end
  end

  defp link_temporary(temporary, path, directory_sync) do
    case :file.make_link(String.to_charlist(temporary), String.to_charlist(path)) do
      :ok -> finish_link(temporary, path, directory_sync)
      {:error, :eexist} -> cleanup_existing_collision(temporary, path, directory_sync)
      {:error, reason} -> cleanup_temporary(temporary, {:error, reason})
    end
  end

  defp finish_link(temporary, path, directory_sync) do
    with :ok <- File.rm(temporary),
         :ok <- directory_sync.(Path.dirname(path)) do
      :ok
    else
      {:error, _reason} = error ->
        _ = File.rm(temporary)
        _ = File.rm(path)
        _ = directory_sync.(Path.dirname(path))
        error
    end
  end

  defp cleanup_temporary(temporary, result) do
    _ = File.rm(temporary)
    result
  end

  defp cleanup_existing_collision(temporary, path, directory_sync) do
    with :ok <- File.rm(temporary),
         :ok <- directory_sync.(Path.dirname(path)) do
      {:error, :artifact_exists}
    else
      {:error, reason} -> {:error, {:artifact_exists_cleanup_failed, reason}}
    end
  end

  defp before_link(opts) do
    case Keyword.get(opts, :before_link) do
      callback when is_function(callback, 0) -> callback.()
      _none -> :ok
    end
  end

  defp write_close(file, content) do
    try do
      with :ok <- :file.write(file, content),
           :ok <- :file.sync(file) do
        :ok
      end
    after
      :file.close(file)
    end
  end

  defp secure_hash_match?(content, expected) when is_binary(expected) do
    actual = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
    byte_size(actual) == byte_size(expected) and :crypto.hash_equals(actual, expected)
  end

  defp secure_hash_match?(_content, _expected), do: false

  defp remove_untracked(
         directory,
         names,
         referenced_paths,
         active_paths,
         stale_after_ms,
         opts
       ) do
    removable =
      Enum.flat_map(names, fn name ->
        candidate = Path.join(directory, name)

        if safely_untracked?(name, candidate, referenced_paths, active_paths, stale_after_ms),
          do: [candidate],
          else: []
      end)

    case Enum.reduce_while(removable, :ok, &remove_candidate/2) do
      :ok when removable == [] -> :ok
      :ok -> Keyword.get(opts, :directory_sync, &sync_directory/1).(directory)
      {:error, _reason} = error -> error
    end
  end

  defp safely_untracked?(name, candidate, referenced_paths, active_paths, stale_after_ms) do
    not protected_artifact_path?(name, candidate, referenced_paths, active_paths) and
      (Regex.match?(@artifact_filename, name) or Regex.match?(@temporary_filename, name)) and
      stale?(candidate, stale_after_ms)
  end

  defp protected_artifact_path?(name, candidate, referenced_paths, active_paths) do
    (Regex.match?(@artifact_filename, name) and MapSet.member?(referenced_paths, candidate)) or
      (Regex.match?(@temporary_filename, name) and
         MapSet.member?(
           active_paths,
           String.replace(candidate, ~r/\.[0-9]+\.tmp\z/, "")
         ))
  end

  defp stale?(path, stale_after_ms) when is_integer(stale_after_ms) and stale_after_ms >= 0 do
    case File.stat(path, time: :posix) do
      {:ok, %{type: :regular, mtime: mtime}} ->
        System.system_time(:millisecond) - mtime * 1_000 >= stale_after_ms

      _invalid ->
        false
    end
  end

  defp remove_candidate(path, :ok) do
    case File.rm(path) do
      :ok -> {:cont, :ok}
      {:error, :enoent} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp sync_existing_directory(directory, directory_sync) do
    if File.dir?(directory), do: directory_sync.(directory), else: :ok
  end

  defp sync_directory(directory) do
    with {:ok, file} <-
           :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      try do
        :file.sync(file)
      after
        :file.close(file)
      end
    end
  end
end
