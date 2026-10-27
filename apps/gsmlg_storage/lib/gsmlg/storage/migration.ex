defmodule GSMLG.Storage.Migration do
  @moduledoc "Explicit, resumable export of legacy SQL metadata before the S3-only runtime starts."

  import Ecto.Query
  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{Catalog, S3Client, StorageFile, StorageFolder}

  @checkpoint ".gsmlg-storage/migrations/catalog-v1.json"

  def export_if_needed do
    has_files = table_exists?("storage_files") and Repo.exists?(StorageFile)
    has_folders = table_exists?("storage_folders") and Repo.exists?(StorageFolder)

    if has_files or has_folders do
      if table_exists?("storage_config"), do: Storage.load_config_from_db()
      ensure_transport()

      with {:ok, backend} <- S3Client.capture_backend() do
        case S3Client.get_object(backend, @checkpoint) do
          {:ok, checkpoint} ->
            validate_checkpoint(checkpoint)

          {:error, {:unexpected_response, %{status_code: 404}}} ->
            case export_catalog(backend: backend) do
              {:ok, summary} ->
                S3Client.put_object(
                  backend,
                  @checkpoint,
                  JSON.encode!(Map.put(summary, :version, 1)),
                  "application/json"
                )

              {:error, _} = error ->
                error
            end

          {:error, _} = error ->
            error
        end
      end
    else
      :ok
    end
  end

  @doc "Exports original IDs/keys without deleting SQL data or overwriting migrated manifests."
  def export_catalog(opts \\ []) do
    with {:ok, backend} <- capture_backend(opts) do
      files =
        if table_exists?("storage_files"),
          do: Repo.all(from(file in StorageFile, order_by: file.id)),
          else: []

      folders = if table_exists?("storage_folders"), do: Repo.all(StorageFolder), else: []

      Enum.reduce_while(files, {:ok, %{exported: 0, skipped: 0, folders: 0}}, fn file,
                                                                                 {:ok, summary} ->
        case export_file(file, backend) do
          {:ok, action} ->
            {:cont, {:ok, Map.update!(summary, action, &(&1 + 1))}}

          {:error, reason} ->
            {:halt, {:error, %{file_id: file.id, reason: reason, completed: summary}}}
        end
      end)
      |> case do
        {:ok, summary} -> export_folders(folders, backend, summary)
        {:error, _} = error -> error
      end
    end
  end

  defp export_file(file, backend) do
    case Catalog.fetch(file.id, backend: backend) do
      {:ok, %{s3_key: key}} when key == file.s3_key ->
        {:ok, :skipped}

      {:ok, _different} ->
        {:error, :manifest_key_conflict}

      {:error, :not_found} ->
        with :ok <- verify_object(file, backend),
             {:ok, _file} <- Catalog.save(file, backend: backend),
             do: {:ok, :exported}

      {:error, _} = error ->
        error
    end
  end

  defp verify_object(%{status: "active", s3_key: key, size: expected}, backend) do
    case S3Client.head_object(backend, key) do
      {:ok, %{size: ^expected}} -> :ok
      {:ok, _different} -> {:error, :legacy_object_size_mismatch}
      {:error, _} = error -> error
    end
  end

  defp verify_object(_file, _backend), do: :ok

  defp export_folders(folders, backend, summary) do
    Enum.reduce_while(folders, {:ok, summary}, fn folder, {:ok, summary} ->
      key = Enum.join(Enum.reject([folder.tenant, folder.type], &is_nil/1), "/") <> "/"

      case export_marker(backend, key) do
        :ok -> {:cont, {:ok, %{summary | folders: summary.folders + 1}}}
        {:error, reason} -> {:halt, {:error, %{folder: key, reason: reason, completed: summary}}}
      end
    end)
  end

  defp export_marker(backend, key) do
    case S3Client.head_object(backend, key) do
      {:ok, %{size: 0}} ->
        :ok

      {:ok, _object} ->
        {:error, :legacy_folder_key_conflict}

      {:error, {:unexpected_response, %{status_code: 404}}} ->
        case S3Client.put_folder_marker(backend, key) do
          {:error, :folder_key_conflict} -> {:error, :legacy_folder_key_conflict}
          result -> result
        end

      {:error, _} = error ->
        error
    end
  end

  defp validate_checkpoint(data) do
    case JSON.decode(data) do
      {:ok, %{"version" => 1, "exported" => exported, "skipped" => skipped, "folders" => folders}}
      when is_integer(exported) and exported >= 0 and is_integer(skipped) and skipped >= 0 and
             is_integer(folders) and folders >= 0 ->
        :ok

      _ ->
        {:error, :invalid_storage_migration_checkpoint}
    end
  end

  defp table_exists?(name) do
    %{rows: [[exists]]} = Repo.query!("SELECT to_regclass($1) IS NOT NULL", [name])
    exists
  end

  defp capture_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} -> {:ok, backend}
      :error -> S3Client.capture_backend()
    end
  end

  defp ensure_transport do
    {:ok, _apps} = Application.ensure_all_started(:http_fetch)
    :ok
  end
end
