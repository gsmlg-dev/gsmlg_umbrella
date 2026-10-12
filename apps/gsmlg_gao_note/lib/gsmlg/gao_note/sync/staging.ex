defmodule GSMLG.GaoNote.Sync.Staging do
  @moduledoc "Durable, expiring attachment reservations for inbound sync tasks."
  alias GSMLG.GaoNote.Sync
  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker
  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.ContentType
  @expiry_seconds 60
  @chunk_bytes 1_048_576

  def upload({filename, bytes}, tenant, type, opts) when is_binary(bytes) do
    expires_at = DateTime.add(DateTime.utc_now(), @expiry_seconds, :second)

    with :ok <- validate_size(bytes),
         {:ok, content_type} <- ContentType.detect(bytes, filename),
         :ok <- validate_content_type(content_type, type),
         attrs <- %{
           filename: filename,
           content_type: content_type,
           size: byte_size(bytes),
           checksum: Sync.Protocol.sha256(bytes),
           expires_at: expires_at
         },
         {:ok, reservation} <- reserve(tenant, type, attrs, opts),
         {:ok, result} <-
           Sync.with_object_lock(reservation.id, fn ->
             with :ok <- write_chunks(reservation.id, bytes),
                  do: Storage.finalize_upload(reservation.id)
           end) do
      result
    end
  end

  def protected?(%{metadata: %{"sync_staging_expires_at" => value}}) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _} -> DateTime.after?(expires_at, DateTime.utc_now())
      _ -> false
    end
  end

  def protected?(_file), do: false

  def reservation?(%{metadata: metadata}), do: Map.has_key?(metadata, "sync_staging_expires_at")

  defp validate_size(bytes) do
    limit = Application.get_env(:gsmlg_storage, :max_file_size, 5 * 1024 * 1024 * 1024)

    if byte_size(bytes) <= limit,
      do: :ok,
      else: {:error, {:file_too_large, byte_size(bytes), limit}}
  end

  defp validate_content_type(content_type, type) do
    allowed = Application.get_env(:gsmlg_storage, :allowed_types, %{}) |> Map.get(type, :any)

    if allowed == :any or content_type in allowed,
      do: :ok,
      else: {:error, {:content_type_not_allowed, content_type, type}}
  end

  defp reserve(tenant, type, attrs, opts) do
    Repo.transaction(fn ->
      with {:ok, file} <- Storage.prepare_upload(tenant, type, attrs, max_bytes: attrs.size),
           metadata <-
             file.metadata
             |> Map.merge(opts[:metadata] || %{})
             |> Map.put("sync_staging_expires_at", DateTime.to_iso8601(attrs.expires_at)),
           {:ok, file} <-
             Repo.update(
               Ecto.Changeset.change(file, metadata: metadata, uploaded_by: opts[:uploaded_by])
             ),
           {:ok, _job} <-
             %{storage_file_id: file.id}
             |> StorageFilePurgeWorker.new(schedule_in: @expiry_seconds)
             |> Oban.insert() do
        file
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write_chunks(_id, ""), do: :ok

  defp write_chunks(id, bytes) do
    size = min(byte_size(bytes), @chunk_bytes)
    <<chunk::binary-size(size), rest::binary>> = bytes
    with :ok <- Storage.write_upload(id, chunk), do: write_chunks(id, rest)
  end
end
