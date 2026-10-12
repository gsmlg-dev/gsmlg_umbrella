defmodule GSMLG.GaoNote.Workers.StorageFilePurgeWorker do
  @moduledoc """
  Permanently removes storage files after their GaoNote attachment is purged.
  """

  use Oban.Worker,
    queue: :storage_cleanup,
    max_attempts: 10,
    unique: [period: 86_400, fields: [:worker, :args]]

  alias GSMLG.GaoNote.Sync
  alias GSMLG.GaoNote.Sync.Staging
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"storage_file_id" => id}}) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> perform_for_id(id)
      :error -> {:cancel, :invalid_storage_file_id}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_storage_file_id}

  defp perform_for_id(id) do
    case Sync.with_object_lock(id, fn ->
           if Sync.object_referenced?(id), do: {:snooze, 60}, else: purge_unreferenced(id)
         end) do
      {:ok, result} -> result
      {:error, _} = error -> error
    end
  end

  defp purge_unreferenced(id) do
    case Storage.get(id) do
      nil ->
        :ok

      %StorageFile{} = file ->
        perform_for_file(file)
    end
  end

  defp perform_for_file(%StorageFile{type: type}) when type != "gao_note_attachment" do
    {:cancel, {:invalid_storage_file_type, type}}
  end

  defp perform_for_file(%StorageFile{variants: variants} = file) do
    cond do
      Staging.protected?(file) -> {:snooze, 60}
      empty_variants?(variants) -> perform_matching_file(file)
      true -> {:cancel, :storage_file_has_variants}
    end
  end

  defp perform_matching_file(%StorageFile{status: "active"} = file),
    do: delete_and_purge(file)

  defp perform_matching_file(%StorageFile{status: "deleted"} = file),
    do: normalize_result(Storage.purge(file))

  defp perform_matching_file(%StorageFile{status: "processing"} = file) do
    if Staging.reservation?(file) do
      case Storage.reject_upload(file) do
        {:ok, deleted} -> normalize_result(Storage.purge(deleted))
        {:error, _} = error -> error
      end
    else
      {:cancel, {:unsupported_status, "processing"}}
    end
  end

  defp perform_matching_file(%StorageFile{status: status}),
    do: {:cancel, {:unsupported_status, status}}

  defp empty_variants?(variants) when is_map(variants), do: map_size(variants) == 0
  defp empty_variants?(_variants), do: false

  defp delete_and_purge(file) do
    case Storage.delete(file) do
      {:ok, deleted} -> normalize_result(Storage.purge(deleted))
      {:error, _reason} = error -> error
    end
  end

  defp normalize_result({:ok, %StorageFile{}}), do: :ok
  defp normalize_result({:error, :not_found}), do: :ok
  defp normalize_result({:error, _reason} = error), do: error
end
