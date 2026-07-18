defmodule GSMLG.Storage do
  @moduledoc """
  Centralized file storage API backed by S3.

  Provides upload, retrieval, streaming, and deletion of files
  with automatic content-type detection, SHA-256 checksums,
  and configurable variant generation for images.
  """

  require Logger

  alias GSMLG.Repo
  alias GSMLG.Storage.{StorageFile, StorageFolder, StorageConfig, S3Client, ContentType}

  import Ecto.Query

  @max_filename_bytes 255

  @doc """
  Uploads a file to S3 and creates a DB record.

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
         checksum <- compute_checksum(data),
         s3_key <- generate_s3_key(tenant, type, filename, content_type),
         bucket <- bucket(),
         :ok <- S3Client.put_object(bucket, s3_key, data, content_type) do
      attrs = %{
        tenant: tenant,
        type: type,
        filename: filename,
        s3_key: s3_key,
        content_type: content_type,
        size: byte_size(data),
        checksum: checksum,
        metadata: opts[:metadata] || %{},
        variants: %{},
        status: "active",
        uploaded_by: opts[:uploaded_by]
      }

      case insert_storage_file(attrs, bucket, s3_key) do
        {:ok, file} ->
          if opts[:variants] != [] do
            maybe_generate_variants(file)
          end

          {:ok, file}

        {:error, changeset} ->
          best_effort_delete_uploaded_object(bucket, s3_key)
          {:error, changeset}
      end
    end
  end

  @doc """
  Gets a storage file by ID. Returns nil if not found or not active.
  """
  def get(id) do
    Repo.get(StorageFile, id)
  end

  @doc """
  Gets an active storage file by ID. Returns nil for deleted/processing files.
  """
  def get_active(id) do
    StorageFile
    |> where([f], f.id == ^id and f.status == "active")
    |> Repo.one()
  end

  @doc """
  Streams a file's content from S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def stream(file_or_id) do
    with {:ok, file} <- resolve_file(file_or_id) do
      S3Client.get_object(bucket(), file.s3_key)
    end
  end

  @doc """
  Reads an inclusive byte range from a file in S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def read_range(file_or_id, first, last) do
    with :ok <- validate_range(first, last),
         {:ok, file} <- resolve_range_file(file_or_id),
         :ok <- validate_range_bounds(file, last) do
      S3Client.get_object_range(bucket(), file.s3_key, first, last)
    end
  end

  @doc """
  Streams a specific variant of a file from S3.

  Returns `{:ok, binary}` or `{:error, reason}`.
  """
  def stream_variant(%StorageFile{variants: variants}, variant_name) do
    case Map.get(variants || %{}, variant_name) do
      %{"s3_key" => s3_key} -> S3Client.get_object(bucket(), s3_key)
      _ -> {:error, :variant_not_found}
    end
  end

  @doc """
  Soft-deletes a file by setting status to "deleted".
  Does not immediately remove from S3.
  """
  def delete(file_or_id) do
    with {:ok, file} <- resolve_file(file_or_id) do
      file
      |> StorageFile.status_changeset(%{status: "deleted"})
      |> Repo.update()
    end
  end

  @doc """
  Permanently purges a soft-deleted file and all its variants from S3.
  Only works on files with status "deleted".
  """
  def purge(%StorageFile{status: "deleted", id: id}) when is_binary(id) do
    case Repo.get(StorageFile, id) do
      nil ->
        {:error, :not_found}

      current_file ->
        with :ok <- ensure_purgeable(current_file) do
          purge_current_file(current_file)
        end
    end
  end

  def purge(_file), do: {:error, :not_deleted}

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
    page = opts[:page] || 1
    page_size = opts[:page_size] || 20
    offset = (page - 1) * page_size

    query =
      StorageFile
      |> filter_by_tenant(opts[:tenant])
      |> filter_by_type(opts[:type])
      |> filter_by_status(opts[:status] || "active")
      |> filter_by_search(opts[:search])
      |> filter_by_year(opts[:year])
      |> filter_by_month(opts[:month])
      |> order_by([f], desc: f.inserted_at)

    total = Repo.aggregate(query, :count)
    files = query |> limit(^page_size) |> offset(^offset) |> Repo.all()

    %{
      files: files,
      total: total,
      page: page,
      page_size: page_size,
      total_pages: max(1, ceil(total / page_size))
    }
  end

  @doc """
  Returns a tree of tenants → types → year/month nodes with file counts.
  Used to populate the file browser sidebar.
  """
  def folder_tree do
    # File-derived groups: {tenant, type, year, month, count}
    file_groups =
      StorageFile
      |> where([f], f.status == "active")
      |> group_by([f], [
        f.tenant,
        f.type,
        fragment("date_part('year', ?)", f.inserted_at),
        fragment("date_part('month', ?)", f.inserted_at)
      ])
      |> select([f], {
        f.tenant,
        f.type,
        fragment("date_part('year', ?)", f.inserted_at),
        fragment("date_part('month', ?)", f.inserted_at),
        count(f.id)
      })
      |> order_by([f], [
        f.tenant,
        f.type,
        desc: fragment("date_part('year', ?)", f.inserted_at),
        desc: fragment("date_part('month', ?)", f.inserted_at)
      ])
      |> Repo.all()

    # Explicit folder records (may be empty of files)
    explicit_folders = Repo.all(StorageFolder)

    # Union of all {tenant, type} pairs from both sources
    file_pairs =
      file_groups
      |> Enum.map(fn {t, ty, _, _, _} -> {t, ty} end)
      |> Enum.uniq()

    folder_pairs =
      explicit_folders
      |> Enum.reject(fn f -> is_nil(f.type) end)
      |> Enum.map(fn f -> {f.tenant, f.type} end)

    explicit_tenants =
      explicit_folders
      |> Enum.map(& &1.tenant)
      |> Enum.uniq()

    all_tenants =
      (Enum.map(file_pairs, fn {t, _} -> t end) ++ explicit_tenants)
      |> Enum.uniq()
      |> Enum.sort()

    Enum.map(all_tenants, fn tenant ->
      file_types =
        file_pairs |> Enum.filter(fn {t, _} -> t == tenant end) |> Enum.map(fn {_, ty} -> ty end)

      folder_types =
        folder_pairs
        |> Enum.filter(fn {t, _} -> t == tenant end)
        |> Enum.map(fn {_, ty} -> ty end)

      tenant_types =
        (file_types ++ folder_types)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      types =
        Enum.map(tenant_types, fn type ->
          months =
            file_groups
            |> Enum.filter(fn {t, ty, _, _, _} -> t == tenant and ty == type end)
            |> Enum.map(fn {_, _, year, month, count} ->
              %{year: trunc(year), month: trunc(month), count: count}
            end)

          %{type: type, months: months}
        end)

      %{tenant: tenant, types: types}
    end)
  end

  @doc """
  Creates an explicit storage folder record (tenant + optional type).
  The folder will appear in the file browser tree even before any files are uploaded.
  """
  def create_folder(tenant, type \\ nil) do
    %StorageFolder{}
    |> StorageFolder.changeset(%{tenant: tenant, type: type})
    |> Repo.insert()
  end

  @doc """
  Deletes a folder and all files within it.

  - `delete_folder(tenant)` — soft-deletes all files for that tenant and removes all
    folder records under that tenant.
  - `delete_folder(tenant, type)` — soft-deletes all files for tenant+type and removes
    that folder record.
  - `delete_folder(tenant, type, year, month)` — soft-deletes only those files (no
    folder record removed since year/month nodes are file-derived).
  """
  def delete_folder(tenant, type \\ nil, year \\ nil, month \\ nil)

  def delete_folder(_tenant, _type, nil, month) when not is_nil(month) do
    {:error, :month_requires_year}
  end

  def delete_folder(tenant, type, year, month) do
    Repo.transaction(fn ->
      # Soft-delete matching files
      query =
        StorageFile
        |> where([f], f.tenant == ^tenant and f.status == "active")
        |> maybe_filter_type(type)
        |> maybe_filter_year(year)
        |> maybe_filter_month(month)

      Repo.update_all(query, set: [status: "deleted"])

      # Remove explicit folder records
      cond do
        not is_nil(year) ->
          # Year/month nodes are file-derived — no folder record to remove
          :ok

        not is_nil(type) ->
          Repo.delete_all(
            from(f in StorageFolder, where: f.tenant == ^tenant and f.type == ^type)
          )

        true ->
          # Tenant-level delete: remove all folder records for this tenant
          Repo.delete_all(from(f in StorageFolder, where: f.tenant == ^tenant))
      end

      :ok
    end)
  end

  defp maybe_filter_type(query, nil), do: query
  defp maybe_filter_type(query, type), do: where(query, [f], f.type == ^type)

  defp maybe_filter_year(query, nil), do: query

  defp maybe_filter_year(query, year) when is_integer(year) do
    where(query, [f], fragment("date_part('year', ?)", f.inserted_at) == ^year)
  end

  defp maybe_filter_month(query, nil), do: query

  defp maybe_filter_month(query, month) when is_integer(month) do
    where(query, [f], fragment("date_part('month', ?)", f.inserted_at) == ^month)
  end

  @doc """
  Returns summary statistics for stored files.
  """
  def stats(tenant \\ nil) do
    query =
      StorageFile
      |> where([f], f.status == "active")
      |> filter_by_tenant(tenant)

    total_files = Repo.aggregate(query, :count)
    total_size = Repo.aggregate(query, :sum, :size) || 0

    type_breakdown =
      query
      |> group_by([f], f.type)
      |> select([f], {f.type, count(f.id), sum(f.size)})
      |> Repo.all()
      |> Enum.map(fn {type, count, size} ->
        %{type: type, count: count, size: size || 0}
      end)

    %{
      total_files: total_files,
      total_size: total_size,
      by_type: type_breakdown
    }
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

  defp insert_storage_file(attrs, bucket, s3_key) do
    try do
      repo = Application.get_env(:gsmlg_storage, :repo, Repo)

      %StorageFile{}
      |> StorageFile.changeset(attrs)
      |> repo.insert()
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        best_effort_delete_uploaded_object(bucket, s3_key)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp best_effort_delete_uploaded_object(bucket, s3_key) do
    try do
      case S3Client.delete_object(bucket, s3_key) do
        :ok -> :ok
        {:error, _reason} -> log_upload_compensation_failure()
      end
    catch
      _kind, _reason -> log_upload_compensation_failure()
    end
  end

  defp log_upload_compensation_failure do
    Logger.warning("S3 cleanup failed after storage row insertion failure")
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

  defp purge_current_file(file) do
    bucket = bucket()

    with :ok <- delete_variant_objects(bucket, file.variants || %{}),
         :ok <- S3Client.delete_object(bucket, file.s3_key),
         {:ok, deleted} <- Repo.delete(file) do
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
    variant_defs = variant_definitions(file.type)

    case S3Client.get_object(bucket(), file.s3_key) do
      {:ok, original_data} ->
        variants =
          Enum.reduce(variant_defs, %{}, fn {name, opts}, acc ->
            case GSMLG.Storage.ImageProcessor.process(original_data, opts) do
              {:ok, processed_data} ->
                variant_ext =
                  opts[:format] || extension_from_content_type(file.content_type, file.filename)

                variant_key = String.replace(file.s3_key, ~r/\.[^.]+$/, "_#{name}.#{variant_ext}")
                variant_ct = content_type_for_format(opts[:format], file.content_type)

                case S3Client.put_object(bucket(), variant_key, processed_data, variant_ct) do
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
          |> Repo.update()
        end

      {:error, reason} ->
        Logger.warning(
          "Failed to fetch original for variant generation, file #{file.id}: #{inspect(reason)}"
        )

        :error
    end
  end

  defp resolve_file(%StorageFile{} = file), do: {:ok, file}

  defp resolve_file(id) when is_binary(id) do
    case Repo.get(StorageFile, id) do
      nil -> {:error, :not_found}
      file -> {:ok, file}
    end
  end

  defp resolve_range_file(%StorageFile{} = file), do: {:ok, file}

  defp resolve_range_file(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} ->
        case Repo.get(StorageFile, id) do
          nil -> {:error, :not_found}
          file -> {:ok, file}
        end

      :error ->
        {:error, :invalid_id}
    end
  end

  defp resolve_range_file(_file_or_id), do: {:error, :invalid_file}

  defp filter_by_tenant(query, nil), do: query
  defp filter_by_tenant(query, tenant), do: where(query, [f], f.tenant == ^tenant)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [f], f.type == ^type)

  defp filter_by_status(query, nil), do: query
  defp filter_by_status(query, status), do: where(query, [f], f.status == ^status)

  defp filter_by_year(query, nil), do: query

  defp filter_by_year(query, year) when is_integer(year) do
    where(query, [f], fragment("date_part('year', ?)", f.inserted_at) == ^year)
  end

  defp filter_by_month(query, nil), do: query

  defp filter_by_month(query, month) when is_integer(month) do
    where(query, [f], fragment("date_part('month', ?)", f.inserted_at) == ^month)
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) do
    escaped =
      search
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")

    pattern = "%#{escaped}%"
    where(query, [f], ilike(f.filename, ^pattern))
  end

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

  defp bucket do
    Application.get_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
  end

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
