defmodule GSMLG.Storage.Inventory do
  @moduledoc "S3 object snapshots and directory projections, without database metadata."

  alias GSMLG.Storage.S3Client

  def backend(config \\ Application.get_all_env(:gsmlg_storage)),
    do: S3Client.capture_backend(config)

  def current_backend_id, do: S3Client.current_backend_id()
  def backend_id(%{id: id}), do: id

  def load(backend) do
    with {:ok, objects} <- S3Client.list_objects(backend) do
      {:ok,
       %{
         backend_id: backend_id(backend),
         bucket: backend.bucket,
         objects: Enum.reject(objects, &GSMLG.Storage.Catalog.internal_key?(&1.key)),
         refreshed_at: DateTime.utc_now()
       }}
    end
  end

  def encode_key(key) when is_binary(key), do: Base.url_encode64(key, padding: false)

  def decode_key(encoded) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, key} when byte_size(key) > 0 -> {:ok, key}
      _ -> {:error, :invalid_object_key}
    end
  end

  def project(objects, opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "")
    search = Keyword.get(opts, :search, "") || ""
    page_size = max(1, Keyword.get(opts, :page_size, 20))
    scoped = Enum.filter(objects, &String.starts_with?(&1.key, prefix))
    folders = child_folders(scoped, prefix)

    files =
      scoped
      |> Enum.reject(& &1.folder?)
      |> Enum.filter(fn object ->
        relative = String.replace_prefix(object.key, prefix, "")

        if search == "" do
          not String.contains?(relative, "/")
        else
          String.contains?(String.downcase(object.key), String.downcase(search))
        end
      end)
      |> Enum.sort_by(& &1.key)

    total = length(files)
    total_pages = max(1, ceil(total / page_size))
    page = Keyword.get(opts, :page, 1) |> max(1) |> min(total_pages)

    %{
      objects: Enum.slice(files, (page - 1) * page_size, page_size),
      total: total,
      page: page,
      page_size: page_size,
      total_pages: total_pages,
      folders: folders,
      stats: %{
        total_files: Enum.count(scoped, &(not &1.folder?)),
        total_size: Enum.reduce(scoped, 0, &(&1.size + &2)),
        total_folders: length(folder_prefixes(scoped, prefix))
      }
    }
  end

  defp child_folders(objects, prefix) do
    objects
    |> Enum.group_by(fn object ->
      relative = String.replace_prefix(object.key, prefix, "")

      case String.split(relative, "/", parts: 2) do
        [name, _] -> prefix <> name <> "/"
        [_] -> nil
      end
    end)
    |> Enum.reject(fn {folder, _} -> is_nil(folder) or folder == prefix end)
    |> Enum.map(fn {folder, children} ->
      %{
        prefix: folder,
        name: String.replace_prefix(folder, prefix, ""),
        count: Enum.count(children, &(not &1.folder?))
      }
    end)
    |> Enum.sort_by(& &1.prefix)
  end

  defp folder_prefixes(objects, prefix) do
    objects
    |> Enum.flat_map(fn object ->
      parts = object.key |> String.split("/") |> Enum.drop(-1)

      parts
      |> Enum.scan("", fn part, path -> path <> part <> "/" end)
      |> Enum.filter(&(String.starts_with?(&1, prefix) and &1 != prefix))
    end)
    |> Enum.uniq()
  end
end
