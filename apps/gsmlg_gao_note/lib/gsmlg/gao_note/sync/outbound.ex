defmodule GSMLG.GaoNote.Sync.Outbound do
  @moduledoc false
  alias GSMLG.GaoNote.Sync.{Protocol, Snapshot}

  # The channel validates the aggregate manifest before creating any files.
  # Each task holds only one remote object; subsequent wire reads are bounded.
  def prepare(directory, storage_id, attachment) do
    with false <- is_nil(storage_id),
         {:ok, bytes} <- Snapshot.read_object(storage_id),
         true <-
           byte_size(bytes) == attachment["size_bytes"] and
             Protocol.sha256(bytes) == attachment["checksum_sha256"] do
      path = Path.join(directory, Protocol.sha256(attachment["id"]))

      with :ok <- File.mkdir_p(directory),
           :ok <- File.chmod(Path.dirname(directory), 0o700),
           :ok <- File.chmod(directory, 0o700),
           :ok <- File.write(path, bytes, [:binary, :exclusive]),
           :ok <- File.chmod(path, 0o600) do
        {:ok, %{path: path, size: byte_size(bytes)}}
      else
        {:error, reason} -> {:error, {:storage, reason}}
      end
    else
      true -> {:error, :object_unavailable}
      false -> {:error, :object_integrity_mismatch}
      {:error, _} = error -> error
    end
  end

  def read_chunk(path, offset, size) when size > 0 and size <= 65_536 do
    with {:ok, file} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case :file.pread(file, offset, size) do
          {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
          {:error, reason} -> {:error, {:storage, reason}}
          _ -> {:error, :object_size_mismatch}
        end
      after
        File.close(file)
      end
    end
  end
end
