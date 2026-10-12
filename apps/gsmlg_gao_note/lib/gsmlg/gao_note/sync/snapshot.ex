defmodule GSMLG.GaoNote.Sync.Snapshot do
  @moduledoc "Builds complete wire snapshots without exposing local storage identities."

  alias GSMLG.GaoNote.{Attachment, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{S3Client, StorageFile}

  @max_blob_bytes 536_870_912
  @chunk_bytes 65_536
  @sha256 ~r/\A[0-9a-fA-F]{64}\z/

  def build(note_id) do
    case Repo.get(Note, note_id) do
      nil -> {:error, :not_found}
      note -> build_note(Repo.preload(note, labels: :label_setting, attachments: :storage_file))
    end
  end

  defp build_note(note) do
    with {:ok, attachments, objects} <- attachment_manifest(note.attachments) do
      labels =
        note.labels
        |> Enum.map(fn label ->
          %{
            "key" => label.label_setting.name,
            "value" => label.value || "",
            "description" => label.label_setting.description || "",
            "value_type" => wire_type(label.label_setting.value_type || "text")
          }
        end)
        |> Enum.sort_by(&{&1["key"], &1["value"]})

      {:ok,
       %{
         snapshot: %{
           "title" => note.title,
           "content" => note.content,
           "labels" => labels,
           "created_at" => seconds(note.created_at),
           "updated_at" => seconds(note.updated_at),
           "deleted_at" => seconds(note.deleted_at),
           "attachments" => Enum.sort_by(attachments, &{&1["path"], &1["id"]})
         },
         objects: objects
       }}
    end
  end

  defp attachment_manifest(attachments) do
    Enum.reduce_while(attachments, {:ok, [], %{}}, fn attachment, {:ok, manifest, objects} ->
      id = attachment.api_id || attachment.id

      with false <- Map.has_key?(objects, id),
           {:ok, "./" <> path} <- Attachment.normalize_path(attachment.path),
           {:ok, size, checksum} <- object_metadata(attachment.storage_file) do
        descriptor = %{
          "id" => id,
          "path" => path,
          "mime" => attachment.mime,
          "description" => attachment.description || "",
          "size_bytes" => size,
          "checksum_sha256" => checksum
        }

        {:cont, {:ok, [descriptor | manifest], Map.put(objects, id, attachment.storage_file_id)}}
      else
        true -> {:halt, {:error, :duplicate_attachment_id}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp object_metadata(%StorageFile{status: "active", size: size, checksum: checksum} = file)
       when is_integer(size) and size >= 0 do
    if is_binary(checksum) and Regex.match?(@sha256, checksum) do
      {:ok, size, String.downcase(checksum)}
    else
      with {:ok, bytes} <- read_file(file), do: {:ok, byte_size(bytes), hash(bytes)}
    end
  end

  defp object_metadata(_file), do: {:error, :object_unavailable}

  def read_object(storage_file_id) do
    case Storage.get_active(storage_file_id) do
      nil -> {:error, :object_unavailable}
      file -> read_file(file)
    end
  end

  defp read_file(%StorageFile{size: size}) when is_integer(size) and size > @max_blob_bytes,
    do: {:error, :object_too_large}

  defp read_file(%StorageFile{size: size} = file) when is_integer(size) and size >= 0 do
    with {:ok, bytes} <- read_chunks(file, 0, []),
         :ok <- verify_checksum(file.checksum, bytes) do
      {:ok, bytes}
    end
  end

  defp read_file(_file), do: {:error, :invalid_object_metadata}

  defp read_chunks(%StorageFile{size: 0} = file, 0, []) do
    bucket = Application.get_env(:gsmlg_storage, :s3_bucket)

    case S3Client.get_object_range(bucket, file.s3_key, 0, 0) do
      {:ok, ""} -> {:ok, ""}
      {:error, {:unexpected_response, %{status_code: 416}}} -> {:ok, ""}
      {:ok, _bytes} -> {:error, :object_size_mismatch}
      {:error, _} = error -> error
    end
  end

  defp read_chunks(%StorageFile{size: size}, size, chunks),
    do: {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

  defp read_chunks(file, offset, chunks) do
    last = min(offset + @chunk_bytes, file.size) - 1

    with {:ok, chunk} <- Storage.read_range(file, offset, last),
         true <- byte_size(chunk) == last - offset + 1 do
      read_chunks(file, last + 1, [chunk | chunks])
    else
      false -> {:error, :object_size_mismatch}
      {:error, _} = error -> error
    end
  end

  defp verify_checksum(checksum, bytes) when is_binary(checksum) do
    if Regex.match?(@sha256, checksum) and String.downcase(checksum) != hash(bytes),
      do: {:error, :object_checksum_mismatch},
      else: :ok
  end

  defp verify_checksum(_checksum, _bytes), do: :ok
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp wire_type("date-time"), do: "datetime"
  defp wire_type(type), do: type
  defp seconds(nil), do: nil
  defp seconds(datetime), do: DateTime.to_unix(datetime)
end
