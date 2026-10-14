defmodule GSMLG.Storage.Catalog do
  @moduledoc "Durable S3 manifests for managed object identities and upload recovery."

  alias GSMLG.Storage.{S3Client, StorageFile}

  @prefix ".gsmlg-storage/objects/"
  @fields ~w(id tenant type filename s3_key content_type size checksum metadata variants status uploaded_by inserted_at updated_at)a

  def internal_key?(key), do: String.starts_with?(key, ".gsmlg-storage/")

  def save(%StorageFile{} = file, opts \\ []) do
    now = DateTime.utc_now()

    file = %{
      file
      | id: file.id || Ecto.UUID.generate(),
        inserted_at: file.inserted_at || now,
        updated_at: file.updated_at || now
    }

    attrs = Map.take(file, @fields)

    with {:ok, _} <- Ecto.UUID.cast(file.id),
         {:ok, _validated} <-
           file |> StorageFile.changeset(attrs) |> Ecto.Changeset.apply_action(:insert),
         :ok <- validate_variants(file.variants),
         {:ok, backend} <- backend(opts),
         :ok <- same_backend(file, backend),
         data <- encode(file),
         :ok <- client(opts).put_object(backend, key(file.id), data, "application/json") do
      {:ok, %{file | backend_id: backend.id}}
    else
      :error -> {:error, :invalid_id}
      {:error, _} = error -> error
    end
  end

  def update(%Ecto.Changeset{} = changeset, opts \\ []) do
    with {:ok, file} <- Ecto.Changeset.apply_action(changeset, :update),
         do: save(%{file | updated_at: DateTime.utc_now()}, opts)
  end

  def fetch(id, opts \\ []) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         {:ok, backend} <- backend(opts),
         {:ok, data} <- client(opts).get_object(backend, key(id)) do
      with {:ok, file} <- decode(data, id), do: {:ok, %{file | backend_id: backend.id}}
    else
      :error -> {:error, :invalid_id}
      {:error, {:unexpected_response, %{status_code: 404}}} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def delete(%StorageFile{} = file, opts \\ []) do
    with {:ok, backend} <- backend(opts),
         :ok <- same_backend(file, backend),
         :ok <- client(opts).delete_object(backend, key(file.id)),
         do: {:ok, file}
  end

  def list(opts \\ []) do
    with {:ok, backend} <- backend(opts),
         {:ok, objects} <- client(opts).list_objects(backend) do
      objects
      |> Enum.filter(
        &(String.starts_with?(&1.key, @prefix) and String.ends_with?(&1.key, ".json"))
      )
      |> Enum.reduce_while({:ok, []}, fn object, {:ok, files} ->
        id = object.key |> String.replace_prefix(@prefix, "") |> String.trim_trailing(".json")

        case fetch(id, Keyword.put(opts, :backend, backend)) do
          {:ok, file} -> {:cont, {:ok, [file | files]}}
          {:error, :not_found} -> {:cont, {:ok, files}}
          {:error, _} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, files} ->
          files =
            files
            |> Enum.reverse()
            |> Enum.filter(&(is_nil(opts[:status]) or &1.status == opts[:status]))

          {:ok, if(opts[:limit], do: Enum.take(files, opts[:limit]), else: files)}

        {:error, _} = error ->
          error
      end
    end
  end

  defp client(opts),
    do:
      Keyword.get(
        opts,
        :client,
        Application.get_env(:gsmlg_storage, :catalog_s3_client, S3Client)
      )

  defp backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} -> {:ok, backend}
      :error -> S3Client.capture_backend()
    end
  end

  defp key(id), do: @prefix <> id <> ".json"

  defp same_backend(%{backend_id: nil}, _backend), do: :ok
  defp same_backend(%{backend_id: id}, %{id: id}), do: :ok
  defp same_backend(_file, _backend), do: {:error, :backend_changed}

  defp encode(file) do
    file
    |> Map.take(@fields)
    |> Map.update!(:inserted_at, &DateTime.to_iso8601/1)
    |> Map.update!(:updated_at, &DateTime.to_iso8601/1)
    |> Map.put(:version, 1)
    |> JSON.encode!()
  end

  defp decode(data, id) do
    with {:ok, %{"id" => ^id, "version" => 1} = attrs} <- JSON.decode(data),
         {:ok, inserted_at, _} <- DateTime.from_iso8601(attrs["inserted_at"]),
         {:ok, updated_at, _} <- DateTime.from_iso8601(attrs["updated_at"]),
         attrs <- Map.new(@fields, &{&1, Map.get(attrs, Atom.to_string(&1))}),
         {:ok, file} <-
           StorageFile.changeset(%StorageFile{id: id}, attrs)
           |> Ecto.Changeset.apply_action(:insert),
         :ok <- validate_variants(file.variants) do
      {:ok, %{file | inserted_at: inserted_at, updated_at: updated_at}}
    else
      _ -> {:error, :invalid_storage_manifest}
    end
  rescue
    _ -> {:error, :invalid_storage_manifest}
  end

  defp validate_variants(nil), do: :ok

  defp validate_variants(variants) when is_map(variants) do
    valid =
      Enum.all?(variants, fn
        {name, %{"s3_key" => key}} when is_binary(name) and is_binary(key) and key != "" ->
          String.valid?(key)

        _ ->
          false
      end)

    if valid, do: :ok, else: {:error, :invalid_storage_manifest}
  end

  defp validate_variants(_variants), do: {:error, :invalid_storage_manifest}
end
