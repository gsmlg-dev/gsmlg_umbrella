defmodule GSMLG.Storage do
  @moduledoc """
  Centralized file storage API backed by S3.

  Provides upload, retrieval, streaming, and deletion of files
  with automatic content-type detection, SHA-256 checksums,
  and configurable variant generation for images.
  """

  require Logger

  alias GSMLG.Repo
  alias GSMLG.Storage.{StorageFile, StorageFolder, StorageConfig, S3Client, ContentType, Catalog}

  import Ecto.Query

  @max_filename_bytes 255

  @doc "Prepares a bounded central upload reservation without persisting a bearer target."
  def prepare_upload(tenant, type, attrs, opts \\ [])

  def prepare_upload(tenant, type, attrs, opts) when is_map(attrs) do
    max_bytes = min(Keyword.get(opts, :max_bytes, max_file_size()), max_file_size())

    with true <- is_binary(tenant) and is_binary(type),
         filename when is_binary(filename) <- attrs[:filename],
         content_type when is_binary(content_type) <- attrs[:content_type],
         size when is_integer(size) and size >= 0 and size <= max_bytes <- attrs[:size],
         checksum when is_binary(checksum) <- attrs[:checksum],
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, checksum),
         %DateTime{} = expires_at <- attrs[:expires_at],
         true <- DateTime.after?(expires_at, DateTime.utc_now()),
         {:ok, sanitized} <- sanitize_filename(filename),
         s3_key <- generate_s3_key(tenant, type, sanitized, content_type),
         reservation <-
           StorageFile.changeset(%StorageFile{}, %{
             tenant: tenant,
             type: type,
             filename: sanitized,
             s3_key: s3_key,
             content_type: content_type,
             size: size,
             checksum: checksum,
             metadata: %{
               "upload_expires_at" => DateTime.to_iso8601(expires_at),
               "max_bytes" => max_bytes
             },
             variants: %{},
             status: "processing"
           }),
         {:ok, backend} <- S3Client.capture_backend(),
         {:ok, file} <- Catalog.update(reservation, backend: backend) do
      case create_reservation_file(file.id) do
        :ok ->
          {:ok, file}

        {:error, _reason} = error ->
          _ = Catalog.delete(file, backend: backend)
          error
      end
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_upload_reservation}
    end
  end

  def prepare_upload(_tenant, _type, _attrs, _opts), do: {:error, :invalid_upload_reservation}

  @doc "Appends one bounded request-body chunk to a durable upload reservation."
  def write_upload(reservation_id, chunk) when is_binary(reservation_id) and is_binary(chunk) do
    with %StorageFile{status: "processing"} = reservation <-
           get(reservation_id),
         true <- not upload_expired?(reservation),
         {:ok, io} <-
           :file.open(String.to_charlist(reservation_path(reservation.id)), [
             :read,
             :write,
             :binary
           ]) do
      result =
        with {:ok, current_size} <- :file.position(io, :eof),
             true <- current_size + byte_size(chunk) <= reservation.size,
             :ok <- :file.write(io, chunk),
             :ok <- :file.sync(io) do
          :ok
        else
          false -> {:error, :upload_too_large}
          {:error, _reason} -> {:error, :upload_write_failed}
        end

      :file.close(io)
      result
    else
      nil -> {:error, :not_found}
      %StorageFile{} -> {:error, :invalid_upload_reservation}
      false -> {:error, :upload_expired}
      {:error, _reason} -> {:error, :upload_write_failed}
    end
  end

  def write_upload(_reservation_id, _chunk), do: {:error, :invalid_upload_chunk}

  @doc "Finalizes a bounded reservation using streaming size/hash and bounded object-store writes."
  def finalize_upload(reservation_id, opts \\ [])

  def finalize_upload(reservation_id, opts) when is_binary(reservation_id) do
    with_locked_file(
      reservation_id,
      fn
        %StorageFile{status: "processing"} = reservation, backend ->
          finalize_reservation(reservation, backend, opts)

        _file, _backend ->
          {:error, :invalid_upload_reservation}
      end,
      protect: false
    )
  end

  def finalize_upload(_reservation_id, _opts), do: {:error, :invalid_upload_reservation}

  defp finalize_reservation(reservation, backend, opts) do
    client = Keyword.get(opts, :s3_client, storage_client())

    with true <- not upload_expired?(reservation),
         path <- reservation_path(reservation.id),
         {:ok, %{size: size, checksum: checksum}} <- hash_file(path),
         true <- size == reservation.size,
         true <- Plug.Crypto.secure_compare(checksum, reservation.checksum),
         {:ok, detected} <- ContentType.detect_file(path, reservation.filename),
         true <- detected == reservation.content_type,
         target <- if(client == S3Client, do: backend, else: backend.bucket),
         :ok <- client.put_file(target, reservation.s3_key, path, reservation.content_type),
         {:ok, active} <-
           reservation
           |> StorageFile.status_changeset(%{status: "active"})
           |> Catalog.update(backend: backend) do
      _ = File.rm(path)
      {:ok, active}
    else
      false -> {:error, :upload_integrity_failed}
      {:error, %Ecto.Changeset{}} -> {:error, :upload_commit_failed}
      {:error, _reason} = error -> error
    end
  end

  @doc "Rejects a reservation, or recoverably soft-deletes a finalized storage object."
  def reject_upload(%StorageFile{} = file), do: reject_upload(file.id, file.backend_id)
  def reject_upload(id) when is_binary(id), do: reject_upload(id, nil)
  def reject_upload(_invalid), do: {:error, :invalid_upload_reservation}

  defp reject_upload(id, backend_id) do
    with_locked_file(id, &reject_current_upload/2, backend_id: backend_id)
  end

  defp reject_current_upload(file, backend) do
    case file do
      %StorageFile{status: "processing"} = file ->
        case File.rm(reservation_path(file.id)) do
          :ok ->
            file
            |> StorageFile.status_changeset(%{status: "deleted"})
            |> Catalog.update(backend: backend)

          {:error, :enoent} ->
            file
            |> StorageFile.status_changeset(%{status: "deleted"})
            |> Catalog.update(backend: backend)

          {:error, _reason} ->
            {:error, :upload_reject_failed}
        end

      file ->
        file
        |> StorageFile.status_changeset(%{status: "deleted"})
        |> Catalog.update(backend: backend)
    end
  end

  @doc "Recovers only processing intents that are still expired after acquiring the object lock."
  def recover_upload(%StorageFile{} = file) do
    with_locked_file(
      file.id,
      fn
        %StorageFile{status: "processing"} = current, backend ->
          expiry = current.metadata["upload_expires_at"]

          case expiry && DateTime.from_iso8601(expiry) do
            {:ok, expires_at, _} ->
              if DateTime.after?(expires_at, DateTime.utc_now()) do
                {:ok, current}
              else
                ensure_unreferenced!(current, reference_tables())
                reject_current_upload(current, backend)
              end

            _ ->
              {:ok, current}
          end

        current, _backend ->
          {:ok, current}
      end,
      protect: false,
      backend_id: file.backend_id
    )
  end

  @doc """
  Uploads a file and its stable identity manifest to S3.

  Accepts:
  - `%Plug.Upload{}` struct
  - File path (string)
  - `{filename, binary}` tuple

  ## Options
  - `:uploaded_by` - identifier for uploader
  - `:metadata` - arbitrary map of metadata

  Returns `{:ok, %StorageFile{}}` or `{:error, reason}`.
  """
  def upload(input, tenant, type, opts \\ []) do
    with {:ok, raw_filename, data} <- normalize_input(input),
         {:ok, filename} <- sanitize_filename(raw_filename),
         :ok <- validate_size(data, type),
         {:ok, content_type} <- ContentType.detect(data, filename),
         :ok <- validate_content_type(content_type, type),
         {:ok, backend} <- capture_current_backend(opts[:backend_id]),
         attrs <- %{
           tenant: tenant,
           type: type,
           filename: filename,
           s3_key: generate_s3_key(tenant, type, filename, content_type),
           content_type: content_type,
           size: byte_size(data),
           checksum: compute_checksum(data),
           metadata:
             Map.put(
               opts[:metadata] || %{},
               "upload_expires_at",
               DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 3600, :second))
             ),
           variants: %{},
           status: "processing",
           uploaded_by: opts[:uploaded_by]
         },
         {:ok, file} <-
           %StorageFile{} |> StorageFile.changeset(attrs) |> Catalog.update(backend: backend) do
      case commit_upload(file, data, backend) do
        {:ok, active} ->
          if opts[:variants] != [], do: maybe_generate_variants(active)
          {:ok, active}

        {:error, _} = error ->
          error
      end
    end
  end

  defp commit_upload(file, data, backend) do
    with_locked_file(
      file.id,
      fn
        %StorageFile{status: "processing"} = current, ^backend ->
          with true <- not upload_expired?(current),
               :ok <- S3Client.put_object(backend, current.s3_key, data, current.content_type),
               {:ok, active} <-
                 current
                 |> StorageFile.status_changeset(%{status: "active"})
                 |> Catalog.update(backend: backend) do
            {:ok, active}
          else
            false ->
              {:error, :upload_integrity_failed}

            {:error, _} = error ->
              compensate_upload(current, backend)
              error
          end

        _file, _backend ->
          {:error, :invalid_upload_reservation}
      end,
      protect: false,
      backend: backend
    )
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__

      try do
        with_locked_file(file.id, &compensate_upload/2, backend: backend)
      catch
        _kind, _reason -> :ok
      end

      :erlang.raise(kind, reason, stacktrace)
  end

  defp compensate_upload(file, backend) do
    _ = S3Client.delete_object(backend, file.s3_key)

    _ =
      file
      |> StorageFile.status_changeset(%{status: "deleted"})
      |> Catalog.update(backend: backend)

    :ok
  catch
    _kind, _reason -> :ok
  end

  @doc """
  Gets a storage file by ID. Returns nil if not found or not active.
  """
  def get(id) do
    case Catalog.fetch(id) do
      {:ok, file} -> file
      {:error, _reason} -> nil
    end
  end

  @doc """
  Gets an active storage file by ID. Returns nil for deleted/processing files.
  """
  def get_active(id) do
    case get(id) do
      %StorageFile{status: "active"} = file -> file
      _ -> nil
    end
  end

  @doc "Updates managed metadata in S3 while retaining the object's stable identity."
  def update_metadata(%StorageFile{} = file, attrs) do
    with_locked_file(
      file.id,
      fn current, backend ->
        current |> StorageFile.changeset(attrs) |> Catalog.update(backend: backend)
      end,
      protect: false,
      backend_id: file.backend_id
    )
  end

  @doc """
  Streams a file's content from S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def stream(file_or_id) do
    with {:ok, file} <- resolve_file(file_or_id),
         {:ok, backend} <- file_backend(file) do
      S3Client.get_object(backend, file.s3_key)
    end
  end

  @doc """
  Reads an inclusive byte range from a file in S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def read_range(file_or_id, first, last) do
    with :ok <- validate_range(first, last),
         {:ok, file} <- resolve_range_file(file_or_id),
         :ok <- validate_range_bounds(file, last),
         {:ok, backend} <- file_backend(file) do
      S3Client.get_object_range(backend, file.s3_key, first, last)
    end
  end

  @doc """
  Streams a specific variant of a file from S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def stream_variant(%StorageFile{variants: variants} = file, variant_name) do
    with {:ok, backend} <- file_backend(file) do
      case Map.get(variants || %{}, variant_name) do
        %{"s3_key" => s3_key} -> S3Client.get_object(backend, s3_key)
        _ -> {:error, :variant_not_found}
      end
    end
  end

  @doc """
  Soft-deletes a file by setting status to "deleted".
  Does not immediately remove from S3.
  """
  def delete(file_or_id) do
    with {:ok, file} <- resolve_file(file_or_id) do
      with_locked_file(
        file.id,
        fn current, backend ->
          current
          |> StorageFile.status_changeset(%{status: "deleted"})
          |> Catalog.update(backend: backend)
        end,
        backend_id: file.backend_id
      )
    end
  end

  @doc """
  Permanently purges a soft-deleted file and all its variants from S3.
  Only works on files with status "deleted".
  """
  def purge(%StorageFile{status: "deleted", id: id} = file) when is_binary(id) do
    with_locked_file(id, &purge_current_file/2, purge: true, backend_id: file.backend_id)
  end

  def purge(_file), do: {:error, :not_deleted}

  @doc "Deletes an exact browser object, retaining managed attachment and sync protections."
  def delete_object(key, backend_id) do
    with :ok <- validate_object_key(key),
         {:ok, backend} <- capture_current_backend(backend_id),
         {:ok, files} <- Catalog.list(backend: backend) do
      case Enum.find(files, &owns_object?(&1, key)) do
        nil ->
          with :ok <- S3Client.delete_object(backend, key), do: {:ok, key}

        file ->
          with_locked_file(
            file.id,
            fn current, backend ->
              delete_managed_object(current, key, backend)
            end,
            backend: backend
          )
      end
    end
  end

  @doc "Creates a zero-byte folder marker on the browser snapshot's backend."
  def create_object_folder(prefix, backend_id) when is_binary(prefix) and prefix != "" do
    key = if String.ends_with?(prefix, "/"), do: prefix, else: prefix <> "/"

    with :ok <- validate_object_key(key),
         {:ok, backend} <- capture_current_backend(backend_id),
         :ok <- S3Client.put_folder_marker(backend, key),
         do: {:ok, key}
  end

  def create_object_folder(_prefix, _backend_id), do: {:error, :invalid_object_key}

  @doc """
  Renames one exact S3 folder segment, retaining managed UUIDs and logical metadata.

  Referenced attachments and live sync readers prevent the operation, as with
  object deletion. Copies complete before manifests change; a failed operation
  keeps copies and original objects needed for recovery instead of rolling S3 back.
  """
  def rename_object_folder(prefix, new_name, backend_id) do
    with :ok <- validate_folder_prefix(prefix),
         {:ok, destination} <- renamed_folder_prefix(prefix, new_name),
         :ok <- validate_folder_prefix(destination) do
      with_object_folder(prefix, backend_id, fn files, objects, backend ->
        with {:ok, all_files} <- Catalog.list(backend: backend),
             :ok <- folder_destination_available(destination, all_files, objects),
             :ok <- validate_folder_copies(prefix, destination, files, objects),
             :ok <- copy_folder_objects(prefix, destination, objects, backend),
             :ok <- rewrite_folder_manifests(prefix, destination, files, backend),
             :ok <- remove_folder_objects(folder_objects(objects, prefix), backend),
             :ok <- ensure_folder_removed(prefix, backend),
             do: {:ok, destination}
      end)
    end
  end

  @doc """
  Deletes an exact folder recursively, checking all managed references first.

  Deleting a managed original also deletes its variants, including variants
  outside the selected prefix. Failed purges retain the deleted manifest for retry.
  """
  def delete_object_folder(prefix, backend_id) do
    with :ok <- validate_folder_prefix(prefix) do
      with_object_folder(prefix, backend_id, fn files, objects, backend ->
        with :ok <- delete_folder_managed_files(prefix, files, objects, backend),
             managed_keys <- Enum.flat_map(files, &file_object_keys/1) |> MapSet.new(),
             raw <-
               objects
               |> folder_objects(prefix)
               |> Enum.reject(&MapSet.member?(managed_keys, &1.key)),
             :ok <- remove_folder_objects(raw, backend),
             :ok <- ensure_folder_removed(prefix, backend),
             do: {:ok, prefix}
      end)
    end
  end

  defp with_object_folder(prefix, backend_id, operation) do
    with {:ok, backend} <- capture_current_backend(backend_id),
         {:ok, files} <- Catalog.list(backend: backend),
         {:ok, objects} <- S3Client.list_objects(backend) do
      affected = folder_files(files, prefix)

      # The checkout deadline must not release UUID locks during a long S3 batch.
      Repo.transaction(
        fn ->
          # Use the same sorted UUID locks as attachment and sync pin writers.
          current = affected |> Enum.sort_by(& &1.id) |> Enum.map(&lock_file(&1.id, backend))

          with :ok <- unchanged_folder_files(affected, current),
               {:ok, fresh_files} <- Catalog.list(backend: backend),
               :ok <- unchanged_folder_files(current, folder_files(fresh_files, prefix)),
               {:ok, fresh_objects} <- S3Client.list_objects(backend),
               selected <- folder_objects(fresh_objects, prefix),
               :ok <- unchanged_folder_objects(folder_objects(objects, prefix), selected),
               :ok <- folder_exists(selected, current),
               :ok <- validate_folder_ownership(current, fresh_files),
               :ok <- current_folder_backend(backend) do
            tables = reference_tables()
            Enum.each(current, &ensure_unreferenced!(&1, tables))
            operation.(current, fresh_objects, backend)
          end
        end,
        timeout: :infinity
      )
      |> case do
        {:ok, result} -> result
        {:error, _} = error -> error
      end
    end
  end

  defp validate_folder_prefix(prefix) when is_binary(prefix) and prefix not in ["", "/"] do
    with :ok <- validate_object_key(prefix) do
      if String.ends_with?(prefix, "/"), do: :ok, else: {:error, :invalid_folder_prefix}
    end
  end

  defp validate_folder_prefix(_prefix), do: {:error, :invalid_folder_prefix}

  defp renamed_folder_prefix(prefix, name) when is_binary(name) do
    if String.valid?(name) and String.trim(name) != "" and name not in [".", ".."] and
         not String.contains?(name, "/") and not Regex.match?(~r/\p{Cc}/u, name) do
      segment = prefix |> String.split("/", trim: false) |> Enum.drop(-1) |> List.last()
      parent_size = byte_size(prefix) - byte_size(segment) - 1
      {:ok, binary_part(prefix, 0, parent_size) <> name <> "/"}
    else
      {:error, :invalid_folder_name}
    end
  end

  defp renamed_folder_prefix(_prefix, _name), do: {:error, :invalid_folder_name}

  defp folder_files(files, prefix),
    do:
      Enum.filter(files, fn file ->
        Enum.any?(file_object_keys(file), &String.starts_with?(&1, prefix))
      end)

  defp file_object_keys(file),
    do: [
      file.s3_key | Enum.map(file.variants || %{}, fn {_name, variant} -> variant["s3_key"] end)
    ]

  defp folder_objects(objects, prefix),
    do: Enum.filter(objects, &String.starts_with?(&1.key, prefix))

  defp folder_exists([], []), do: {:error, :folder_not_found}
  defp folder_exists(_objects, _files), do: :ok

  defp unchanged_folder_files(before, after_files) do
    cond do
      Enum.any?(after_files, &(&1.status == "processing")) ->
        {:error, :file_processing}

      Enum.sort_by(before, & &1.id) != Enum.sort_by(after_files, & &1.id) ->
        {:error, :folder_changed}

      true ->
        :ok
    end
  end

  defp unchanged_folder_objects(before, after_objects) do
    if Enum.sort_by(before, & &1.key) == Enum.sort_by(after_objects, & &1.key),
      do: :ok,
      else: {:error, :folder_changed}
  end

  defp validate_folder_ownership(affected, files) do
    keys = Enum.flat_map(affected, &file_object_keys/1)
    affected_keys = MapSet.new(keys)

    case Enum.find(keys, &Catalog.internal_key?/1) do
      nil ->
        owners =
          Enum.flat_map(files, &file_object_keys/1)
          |> Enum.filter(&MapSet.member?(affected_keys, &1))

        if length(owners) == MapSet.size(affected_keys),
          do: :ok,
          else: {:error, :object_key_conflict}

      _key ->
        {:error, :reserved_storage_key}
    end
  end

  defp folder_destination_available(destination, files, objects) do
    if Enum.any?(objects, &String.starts_with?(&1.key, destination)) or
         folder_files(files, destination) != [],
       do: {:error, :folder_exists},
       else: :ok
  end

  defp validate_folder_copies(prefix, destination, files, objects) do
    keys = MapSet.new(objects, & &1.key)

    managed =
      Enum.flat_map(files, &file_object_keys/1) |> Enum.filter(&String.starts_with?(&1, prefix))

    cond do
      Enum.any?(managed, &(not MapSet.member?(keys, &1))) ->
        {:error, :folder_changed}

      Enum.any?(
        folder_objects(objects, prefix),
        &(byte_size(move_folder_key(&1.key, prefix, destination)) > 1024)
      ) ->
        {:error, :invalid_folder_name}

      true ->
        :ok
    end
  end

  defp copy_folder_objects(prefix, destination, objects, backend) do
    objects
    |> folder_objects(prefix)
    |> Enum.reduce_while(:ok, fn object, :ok ->
      result =
        with :ok <- current_folder_backend(backend),
             do:
               S3Client.copy_object(
                 backend,
                 object.key,
                 move_folder_key(object.key, prefix, destination),
                 object.etag
               )

      folder_step(result, :copy, object.key)
    end)
  end

  defp rewrite_folder_manifests(prefix, destination, files, backend) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      variants =
        Map.new(file.variants || %{}, fn {name, variant} ->
          {name, Map.update!(variant, "s3_key", &move_folder_key(&1, prefix, destination))}
        end)

      result =
        with :ok <- current_folder_backend(backend) do
          file
          |> StorageFile.changeset(%{
            s3_key: move_folder_key(file.s3_key, prefix, destination),
            variants: variants
          })
          |> Catalog.update(backend: backend)
        end

      folder_step(result, :manifest, file.id)
    end)
  end

  defp move_folder_key(key, prefix, destination),
    do:
      if(String.starts_with?(key, prefix),
        do:
          destination <> binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
        else: key
      )

  defp remove_folder_objects(objects, backend) do
    Enum.reduce_while(objects, :ok, fn object, :ok ->
      result =
        with :ok <- current_folder_backend(backend),
             do: S3Client.delete_object(backend, object.key, object.etag)

      folder_step(result, :delete, object.key)
    end)
  end

  defp folder_step(:ok, _stage, _key), do: {:cont, :ok}
  defp folder_step({:ok, _file}, _stage, _key), do: {:cont, :ok}

  defp folder_step({:error, reason}, stage, key),
    do: {:halt, {:error, {:folder_operation_failed, stage, key, reason}}}

  defp delete_folder_managed_files(prefix, files, objects, backend) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      result = delete_folder_managed_file(prefix, file, objects, backend)
      folder_step(result, :managed_delete, file.id)
    end)
  end

  defp delete_folder_managed_file(prefix, file, objects, backend) do
    if String.starts_with?(file.s3_key, prefix) do
      with :ok <- current_folder_backend(backend),
           {:ok, deleted} <-
             file
             |> StorageFile.status_changeset(%{status: "deleted"})
             |> Catalog.update(backend: backend),
           keys <- MapSet.new(file_object_keys(file)),
           :ok <-
             remove_folder_objects(Enum.filter(objects, &MapSet.member?(keys, &1.key)), backend),
           :ok <- current_folder_backend(backend),
           {:ok, _} <- Catalog.delete(deleted, backend: backend),
           do: :ok
    else
      variants =
        Map.reject(file.variants || %{}, fn {_name, variant} ->
          String.starts_with?(variant["s3_key"], prefix)
        end)

      keys =
        file_object_keys(file) |> Enum.filter(&String.starts_with?(&1, prefix)) |> MapSet.new()

      with :ok <- current_folder_backend(backend),
           {:ok, _} <-
             file
             |> StorageFile.variants_changeset(%{variants: variants})
             |> Catalog.update(backend: backend),
           do: remove_folder_objects(Enum.filter(objects, &MapSet.member?(keys, &1.key)), backend)
    end
  end

  defp current_folder_backend(backend) do
    if S3Client.current_backend_id() == backend.id, do: :ok, else: {:error, :backend_changed}
  end

  defp ensure_folder_removed(prefix, backend) do
    with :ok <- current_folder_backend(backend),
         {:ok, objects} <- S3Client.list_objects(backend),
         {:ok, files} <- Catalog.list(backend: backend) do
      if folder_objects(objects, prefix) == [] and folder_files(files, prefix) == [],
        do: :ok,
        else: {:error, {:folder_operation_failed, :cleanup, prefix, :folder_changed}}
    end
  end

  defp delete_managed_object(%{s3_key: key} = file, key, backend) do
    with {:ok, deleted} <-
           file
           |> StorageFile.status_changeset(%{status: "deleted"})
           |> Catalog.update(backend: backend),
         {:ok, _file} <- purge_current_file(deleted, backend),
         do: {:ok, key}
  end

  defp delete_managed_object(file, key, backend) do
    variants =
      Map.reject(file.variants || %{}, fn {_name, variant} -> variant["s3_key"] == key end)

    with true <- owns_object?(file, key),
         :ok <- S3Client.delete_object(backend, key),
         {:ok, _file} <-
           file
           |> StorageFile.variants_changeset(%{variants: variants})
           |> Catalog.update(backend: backend) do
      {:ok, key}
    else
      false -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  defp owns_object?(file, key),
    do:
      file.s3_key == key or
        Enum.any?(file.variants || %{}, fn {_name, variant} -> variant["s3_key"] == key end)

  defp validate_object_key(key) when is_binary(key) and key != "" do
    cond do
      not String.valid?(key) -> {:error, :invalid_object_key}
      Catalog.internal_key?(key) -> {:error, :reserved_storage_key}
      true -> :ok
    end
  end

  defp validate_object_key(_key), do: {:error, :invalid_object_key}

  @doc """
  Lists files with filtering and pagination.

  ## Options
  - `:tenant` - filter by tenant
  - `:type` - filter by type
  - `:status` - filter by status (default: "active")
  - `:search` - search by filename
  - `:year` - filter by upload year (integer)
  - `:month` - filter by upload month (integer)
  - `:page` - page number (default: 1)
  - `:page_size` - items per page (default: 20)
  """
  def list(opts \\ []) do
    with {:ok, files} <- Catalog.list(status: opts[:status] || "active") do
      files = filter_managed(files, opts) |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      page_size = max(1, opts[:page_size] || 20)
      total = length(files)
      pages = max(1, ceil(total / page_size))
      page = max(1, opts[:page] || 1) |> min(pages)

      %{
        files: Enum.slice(files, (page - 1) * page_size, page_size),
        total: total,
        page: page,
        page_size: page_size,
        total_pages: pages
      }
    end
  end

  @doc "Managed folders and dates, derived from S3 manifests and directory markers."
  def folder_tree do
    with {:ok, backend} <- S3Client.capture_backend(),
         {:ok, files} <- Catalog.list(status: "active", backend: backend),
         {:ok, objects} <- S3Client.list_objects(backend) do
      markers =
        objects
        |> Enum.filter(& &1.folder?)
        |> Enum.map(fn object -> String.split(String.trim_trailing(object.key, "/"), "/") end)
        |> Enum.filter(&(length(&1) in [1, 2]))

      tenants =
        (Enum.map(files, & &1.tenant) ++ Enum.map(markers, &hd/1)) |> Enum.uniq() |> Enum.sort()

      Enum.map(tenants, fn tenant ->
        scoped = Enum.filter(files, &(&1.tenant == tenant))

        types =
          (Enum.map(scoped, & &1.type) ++
             Enum.flat_map(markers, fn
               [^tenant, type] -> [type]
               _ -> []
             end))
          |> Enum.uniq()
          |> Enum.sort()

        %{
          tenant: tenant,
          types:
            Enum.map(types, fn type ->
              months =
                scoped
                |> Enum.filter(&(&1.type == type))
                |> Enum.group_by(&{&1.inserted_at.year, &1.inserted_at.month})
                |> Enum.map(fn {{year, month}, fs} ->
                  %{year: year, month: month, count: length(fs)}
                end)
                |> Enum.sort_by(&{&1.year, &1.month}, :desc)

              %{type: type, months: months}
            end)
        }
      end)
    end
  end

  @doc "Creates an empty S3 directory marker, without writing a folder table."
  def create_folder(tenant, type \\ nil) do
    with {:ok, folder} <-
           %StorageFolder{}
           |> StorageFolder.changeset(%{tenant: tenant, type: type})
           |> Ecto.Changeset.apply_action(:insert),
         {:ok, backend} <- S3Client.capture_backend(),
         key <- Enum.join(Enum.reject([tenant, type], &is_nil/1), "/") <> "/",
         :ok <- S3Client.put_folder_marker(backend, key) do
      {:ok, folder}
    end
  end

  @doc "Soft-deletes managed objects in a folder, preserving domain reference protection."
  def delete_folder(tenant, type \\ nil, year \\ nil, month \\ nil)

  def delete_folder(_tenant, _type, nil, month) when not is_nil(month),
    do: {:error, :month_requires_year}

  def delete_folder(tenant, type, year, month) do
    with {:ok, backend} <- S3Client.capture_backend(),
         {:ok, files} <- Catalog.list(status: "active", backend: backend) do
      files =
        filter_managed(files, tenant: tenant, type: type, year: year, month: month)
        |> Enum.sort_by(& &1.id)

      Repo.transaction(fn ->
        tables = reference_tables()

        current_files =
          Enum.map(files, fn file ->
            current = lock_file(file.id, backend)
            ensure_unreferenced!(current, tables)
            current
          end)

        Enum.each(current_files, fn file ->
          case file
               |> StorageFile.status_changeset(%{status: "deleted"})
               |> Catalog.update(backend: backend) do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        if is_nil(year) do
          prefix = Enum.join(Enum.reject([tenant, type], &is_nil/1), "/") <> "/"

          case S3Client.delete_object(backend, prefix) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        :ok
      end)
    end
  end

  @doc "Summary statistics for managed S3 objects."
  def stats(tenant \\ nil) do
    with {:ok, files} <- Catalog.list(status: "active") do
      files = filter_managed(files, tenant: tenant)

      %{
        total_files: length(files),
        total_size: Enum.sum(Enum.map(files, & &1.size)),
        by_type:
          files
          |> Enum.group_by(& &1.type)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {type, fs} ->
            %{type: type, count: length(fs), size: Enum.sum(Enum.map(fs, & &1.size))}
          end)
      }
    end
  end

  defp filter_managed(files, opts) do
    Enum.filter(files, fn file ->
      (is_nil(opts[:tenant]) or file.tenant == opts[:tenant]) and
        (is_nil(opts[:type]) or file.type == opts[:type]) and
        (is_nil(opts[:year]) or file.inserted_at.year == opts[:year]) and
        (is_nil(opts[:month]) or file.inserted_at.month == opts[:month]) and
        (opts[:search] in [nil, ""] or
           String.contains?(String.downcase(file.filename), String.downcase(opts[:search])))
    end)
  end

  @doc """
  Regenerates variants for a file.
  """
  def regenerate_variants(%StorageFile{} = file) do
    if ContentType.image?(file.content_type) do
      Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
        do_generate_variants(file)
      end)

      :ok
    else
      {:error, :not_an_image}
    end
  end

  # --- Private ---

  defp with_locked_file(id, operation, opts) do
    with {:ok, backend} <- locked_backend(opts) do
      Repo.transaction(fn ->
        file = lock_file(id, backend)

        if opts[:backend_id] && file.backend_id != opts[:backend_id],
          do: Repo.rollback(:backend_changed)

        # Re-read the status before checking references, even for stale caller structs.
        if opts[:purge] do
          case ensure_purgeable(file) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        if Keyword.get(opts, :protect, true), do: ensure_unreferenced!(file, reference_tables())

        # A retryable S3 error must not roll back an enclosing cleanup transaction's
        # soft-delete. Preserve the deleted state so later attempts can resume.
        operation.(file, backend)
      end)
      |> case do
        {:ok, result} -> result
        {:error, _reason} = error -> error
      end
    end
  end

  defp locked_backend(opts) do
    case Keyword.fetch(opts, :backend) do
      {:ok, backend} -> {:ok, backend}
      :error -> capture_current_backend(opts[:backend_id])
    end
  end

  defp lock_file(id, backend) do
    id = Ecto.UUID.cast!(id)
    # Shared with GaoNote Sync.Objects: references cannot appear during deletion.
    Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "gao-note-sync:object:" <> id
    ])

    case Catalog.fetch(id, backend: backend) do
      {:ok, file} -> file
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp reference_tables do
    %{rows: [[attachments, pins, records]]} =
      Repo.query!("""
      SELECT to_regclass('gao_note_attachments') IS NOT NULL,
             to_regclass('gao_note_sync_pins') IS NOT NULL,
             to_regclass('gao_note_sync_records') IS NOT NULL
      """)

    %{attachments: attachments, pins: pins, records: records}
  end

  defp ensure_unreferenced!(file, tables) do
    if tables.pins and tables.records do
      owners =
        from(pin in "gao_note_sync_pins",
          where: pin.storage_file_id == type(^file.id, Ecto.UUID),
          select: pin.owner_id
        )

      now = System.system_time(:millisecond)

      # Conditional deletion serializes with lease renewal; FK cascades release pins.
      Repo.delete_all(
        from(record in "gao_note_sync_records",
          where: record.kind == "lease" and record.id in subquery(owners),
          where: fragment("(?->>'expires_at')::bigint <= ?", record.data, ^now)
        )
      )
    end

    referenced =
      (tables.attachments and
         Repo.exists?(
           from(attachment in "gao_note_attachments",
             where: attachment.storage_file_id == type(^file.id, Ecto.UUID)
           )
         )) or
        (tables.pins and
           Repo.exists?(
             from(pin in "gao_note_sync_pins",
               where: pin.storage_file_id == type(^file.id, Ecto.UUID)
             )
           ))

    if referenced, do: Repo.rollback(:file_referenced)
    :ok
  end

  defp validate_range(first, last)
       when is_integer(first) and is_integer(last) and first >= 0 and last >= first,
       do: :ok

  defp validate_range(_first, _last), do: {:error, :invalid_range}

  defp validate_range_bounds(%StorageFile{size: size}, last)
       when is_integer(size) and last < size,
       do: :ok

  defp validate_range_bounds(%StorageFile{}, _last), do: {:error, :range_out_of_bounds}

  defp ensure_purgeable(%StorageFile{status: "deleted"}), do: :ok
  defp ensure_purgeable(%StorageFile{}), do: {:error, :not_deleted}

  defp purge_current_file(file, backend) do
    with :ok <- delete_variant_objects(backend, file.variants || %{}),
         :ok <- S3Client.delete_object(backend, file.s3_key),
         {:ok, deleted} <- Catalog.delete(file, backend: backend) do
      {:ok, deleted}
    end
  end

  defp delete_variant_objects(bucket, variants) do
    Enum.reduce_while(variants, :ok, fn
      {_name, %{"s3_key" => variant_key}}, :ok when is_binary(variant_key) ->
        case S3Client.delete_object(bucket, variant_key) do
          :ok -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end

      {name, _variant}, :ok ->
        {:halt, {:error, {:invalid_variant, name}}}
    end)
  end

  defp normalize_input(%{__struct__: Plug.Upload} = upload) do
    case File.read(upload.path) do
      {:ok, data} -> {:ok, upload.filename, data}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp normalize_input({filename, data}) when is_binary(filename) and is_binary(data) do
    {:ok, filename, data}
  end

  defp normalize_input(path) when is_binary(path) do
    case File.read(path) do
      {:ok, data} -> {:ok, path, data}
      {:error, reason} -> {:error, {:file_read_error, reason}}
    end
  end

  defp normalize_input(_), do: {:error, :invalid_input}

  defp sanitize_filename(filename) when is_binary(filename) do
    cond do
      not String.valid?(filename) ->
        {:error, :invalid_filename}

      invalid_filename_controls?(filename) ->
        {:error, :invalid_filename}

      true ->
        filename =
          filename
          |> String.replace("\\", "/")
          |> Path.basename()
          |> String.trim()

        cond do
          filename in ["", ".", "..", "/"] -> {:error, :invalid_filename}
          String.contains?(filename, "/") -> {:error, :invalid_filename}
          byte_size(filename) > @max_filename_bytes -> {:error, :invalid_filename}
          true -> {:ok, filename}
        end
    end
  end

  defp sanitize_filename(_filename), do: {:error, :invalid_filename}

  defp invalid_filename_controls?(filename) do
    filename
    |> String.to_charlist()
    |> Enum.any?(fn codepoint -> codepoint < 0x20 or codepoint in 0x7F..0x9F end)
  end

  defp validate_content_type(content_type, type) do
    allowed = allowed_types(type)

    if allowed == :any or content_type in allowed do
      :ok
    else
      {:error, {:content_type_not_allowed, content_type, type}}
    end
  end

  defp validate_size(data, _type) do
    max_size = max_file_size()

    if byte_size(data) <= max_size do
      :ok
    else
      {:error, {:file_too_large, byte_size(data), max_size}}
    end
  end

  defp compute_checksum(data) do
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
  end

  defp generate_s3_key(tenant, type, filename, content_type) do
    now = DateTime.utc_now()
    uuid = Ecto.UUID.generate()
    ext = extension_from_content_type(content_type, filename)
    yyyy = now.year |> Integer.to_string() |> String.pad_leading(4, "0")
    mm = now.month |> Integer.to_string() |> String.pad_leading(2, "0")

    "#{tenant}/#{type}/#{yyyy}/#{mm}/#{uuid}.#{ext}"
  end

  defp extension_from_content_type(content_type, filename) do
    # Try to get extension from content type first, fall back to filename
    case content_type do
      "image/jpeg" -> "jpg"
      "image/png" -> "png"
      "image/gif" -> "gif"
      "image/webp" -> "webp"
      "image/svg+xml" -> "svg"
      "application/pdf" -> "pdf"
      "text/plain" -> "txt"
      "text/html" -> "html"
      "application/json" -> "json"
      _ -> Path.extname(filename) |> String.trim_leading(".")
    end
  end

  defp content_type_for_format("webp", _original), do: "image/webp"
  defp content_type_for_format("png", _original), do: "image/png"
  defp content_type_for_format("jpeg", _original), do: "image/jpeg"
  defp content_type_for_format("jpg", _original), do: "image/jpeg"
  defp content_type_for_format(_no_conversion, original), do: original

  defp maybe_generate_variants(%StorageFile{content_type: ct} = file) do
    if ContentType.image?(ct) do
      Task.Supervisor.start_child(GSMLG.TaskSupervisor, fn ->
        do_generate_variants(file)
      end)
    end
  end

  defp do_generate_variants(%StorageFile{} = file) do
    with_locked_file(
      file.id,
      fn
        %StorageFile{status: "active"} = current, backend ->
          generate_current_variants(current, backend)

        _file, _backend ->
          {:error, :not_active}
      end,
      protect: false,
      backend_id: file.backend_id
    )
  end

  defp generate_current_variants(file, backend) do
    variant_defs = variant_definitions(file.type)

    case S3Client.get_object(backend, file.s3_key) do
      {:ok, original_data} ->
        variants =
          Enum.reduce(variant_defs, %{}, fn {name, opts}, acc ->
            case GSMLG.Storage.ImageProcessor.process(original_data, opts) do
              {:ok, processed_data} ->
                variant_ext =
                  opts[:format] || extension_from_content_type(file.content_type, file.filename)

                variant_key = String.replace(file.s3_key, ~r/\.[^.]+$/, "_#{name}.#{variant_ext}")
                variant_ct = content_type_for_format(opts[:format], file.content_type)

                S3Client.put_object(backend, variant_key, processed_data, variant_ct)
                |> case do
                  :ok ->
                    Map.put(acc, to_string(name), %{
                      "s3_key" => variant_key,
                      "size" => byte_size(processed_data),
                      "content_type" => variant_ct
                    })

                  {:error, reason} ->
                    Logger.warning(
                      "Variant #{name} S3 upload failed for file #{file.id}: #{inspect(reason)}"
                    )

                    acc
                end

              {:error, reason} ->
                Logger.warning(
                  "Variant #{name} processing failed for file #{file.id}: #{inspect(reason)}"
                )

                acc
            end
          end)

        if map_size(variants) > 0 do
          file
          |> StorageFile.variants_changeset(%{
            variants: Map.merge(file.variants || %{}, variants)
          })
          |> Catalog.update(backend: backend)
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch original for variant generation, file #{file.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp file_backend(file) do
    capture_current_backend(file.backend_id)
  end

  defp capture_current_backend(expected_id) do
    with {:ok, backend} <- S3Client.capture_backend() do
      if is_nil(expected_id) or expected_id == backend.id,
        do: {:ok, backend},
        else: {:error, :backend_changed}
    end
  end

  defp resolve_file(%StorageFile{} = file), do: {:ok, file}

  defp resolve_file(id) when is_binary(id) do
    case get(id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  defp resolve_range_file(%StorageFile{} = file), do: {:ok, file}

  defp resolve_range_file(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case get(id) do
          nil -> {:error, :not_found}
          file -> {:ok, file}
        end

      :error ->
        {:error, :invalid_id}
    end
  end

  defp resolve_range_file(_file_or_id), do: {:error, :invalid_file}

  # --- Public config API ---

  @doc """
  Returns the current storage configuration from the database.
  Falls back to an empty struct if not yet configured.
  """
  def get_config do
    Repo.get(StorageConfig, 1) || %StorageConfig{}
  end

  @doc """
  Saves storage configuration to the database and applies it to
  the runtime Application env so changes take effect immediately.
  """
  def update_config(attrs) do
    config = Repo.get(StorageConfig, 1) || %StorageConfig{id: 1}

    config
    |> StorageConfig.changeset(attrs)
    |> Repo.insert_or_update()
    |> case do
      {:ok, saved} ->
        apply_config(saved)

        Phoenix.PubSub.broadcast(GSMLG.PubSub, "storage:config", {
          :storage_backend_changed,
          GSMLG.Storage.Inventory.current_backend_id()
        })

        {:ok, saved}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Loads config from DB and applies to Application env.
  Called on application startup.
  """
  def load_config_from_db do
    case Repo.get(StorageConfig, 1) do
      nil -> :ok
      config -> apply_config(config)
    end
  end

  defp apply_config(config) do
    if config.s3_bucket, do: Application.put_env(:gsmlg_storage, :s3_bucket, config.s3_bucket)

    if config.s3_endpoint in [nil, ""] do
      Application.delete_env(:gsmlg_storage, :s3_endpoint)
    else
      Application.put_env(:gsmlg_storage, :s3_endpoint, config.s3_endpoint)
    end

    if config.s3_region,
      do: Application.put_env(:gsmlg_storage, :s3_region, config.s3_region)

    if config.s3_access_key_id,
      do:
        Application.put_env(
          :gsmlg_storage,
          :s3_access_key_id,
          config.s3_access_key_id
        )

    if config.s3_secret_access_key,
      do:
        Application.put_env(
          :gsmlg_storage,
          :s3_secret_access_key,
          config.s3_secret_access_key
        )

    if config.max_file_size,
      do: Application.put_env(:gsmlg_storage, :max_file_size, config.max_file_size)

    if config.cleanup_interval,
      do: Application.put_env(:gsmlg_storage, :cleanup_interval, config.cleanup_interval)

    if config.retention_window,
      do: Application.put_env(:gsmlg_storage, :retention_window, config.retention_window)

    :ok
  end

  # --- Configuration ---

  defp create_reservation_file(reservation_id) do
    with :ok <- File.mkdir_p(reservation_dir()),
         {:ok, io} <-
           :file.open(String.to_charlist(reservation_path(reservation_id)), [
             :write,
             :binary,
             :exclusive
           ]) do
      :file.close(io)
    else
      {:error, :eexist} -> :ok
      {:error, _reason} -> {:error, :upload_reservation_failed}
    end
  end

  defp hash_file(path) do
    with {:ok, io} <- File.open(path, [:read, :binary]) do
      try do
        hash_file_chunks(io, :crypto.hash_init(:sha256), 0)
      after
        File.close(io)
      end
    else
      {:error, _reason} -> {:error, :upload_read_failed}
    end
  end

  defp hash_file_chunks(io, hash, size) do
    case IO.binread(io, 1_048_576) do
      :eof ->
        {:ok,
         %{
           size: size,
           checksum: :crypto.hash_final(hash) |> Base.encode16(case: :lower)
         }}

      {:error, _reason} ->
        {:error, :upload_read_failed}

      chunk ->
        hash_file_chunks(io, :crypto.hash_update(hash, chunk), size + byte_size(chunk))
    end
  end

  defp upload_expired?(%StorageFile{metadata: %{"upload_expires_at" => value}}) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} -> not DateTime.after?(expires_at, DateTime.utc_now())
      _invalid -> true
    end
  end

  defp upload_expired?(_file), do: true

  defp reservation_path(reservation_id), do: Path.join(reservation_dir(), reservation_id)

  defp reservation_dir do
    Application.get_env(
      :gsmlg_storage,
      :upload_reservation_dir,
      Path.join(System.tmp_dir!(), "gsmlg-storage-uploads")
    )
  end

  defp storage_client,
    do: Application.get_env(:gsmlg_storage, :upload_s3_client, S3Client)

  defp max_file_size do
    Application.get_env(:gsmlg_storage, :max_file_size, 5 * 1024 * 1024 * 1024)
  end

  defp allowed_types(type) do
    config = Application.get_env(:gsmlg_storage, :allowed_types, %{})
    Map.get(config, type, :any)
  end

  defp variant_definitions(type) do
    config = Application.get_env(:gsmlg_storage, :variant_definitions, %{})

    Map.get(config, type, %{
      "thumb" => [width: 150, height: 150, crop: :center],
      "medium" => [width: 800, height: 600]
    })
  end
end
