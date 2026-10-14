defmodule GSMLG.Storage.TestCatalogClient do
  @moduledoc false

  alias GSMLG.Storage.{Catalog, StorageFile}

  def setup! do
    keys = [:catalog_s3_client, :catalog_test_state, :s3_access_key_id, :s3_secret_access_key]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    # Keep manifests available to the existing on_exit crash-recovery cleanup.
    {:ok, state} = Agent.start(fn -> %{} end)
    Application.put_env(:gsmlg_storage, :catalog_s3_client, __MODULE__)
    Application.put_env(:gsmlg_storage, :catalog_test_state, state)
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-key")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret")

    ExUnit.Callbacks.on_exit(fn ->
      Agent.stop(state)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    state
  end

  def get_object(backend, key) do
    Agent.get(state(), fn objects ->
      case Map.fetch(objects, {backend.bucket, key}) do
        {:ok, data} -> {:ok, data}
        :error -> {:error, :not_found}
      end
    end)
  end

  def put_object(backend, key, data, _content_type) do
    Agent.update(state(), &Map.put(&1, {backend.bucket, key}, data))
    :ok
  end

  def delete_object(backend, key) do
    Agent.update(state(), &Map.delete(&1, {backend.bucket, key}))
    :ok
  end

  def list_objects(backend) do
    objects =
      Agent.get(state(), fn objects ->
        for {{bucket, key}, data} <- objects, bucket == backend.bucket do
          %{
            key: key,
            size: byte_size(data),
            last_modified: "2026-10-14T00:00:00Z",
            etag: "test",
            folder?: false
          }
        end
      end)

    {:ok, objects}
  end

  def insert_file!(%Ecto.Changeset{} = changeset),
    do: changeset |> Ecto.Changeset.apply_changes() |> insert_file!()

  def insert_file!(%StorageFile{} = file) do
    {:ok, saved} = Catalog.save(file)
    saved
  end

  def files(opts \\ []) do
    {:ok, files} = Catalog.list(opts)
    files
  end

  def count(opts \\ []), do: length(files(opts))

  def get_file!(id) do
    %StorageFile{} = GSMLG.Storage.get(id)
  end

  def update_file!(%Ecto.Changeset{} = changeset) do
    result =
      if Map.has_key?(changeset.changes, :updated_at),
        do: Catalog.save(Ecto.Changeset.apply_changes(changeset)),
        else: Catalog.update(changeset)

    {:ok, file} = result
    file
  end

  def delete_file!(file) do
    {:ok, deleted} = Catalog.delete(file)
    deleted
  end

  def mutate_manifest!(id, mutation) do
    {:ok, backend} = GSMLG.Storage.S3Client.capture_backend()
    key = ".gsmlg-storage/objects/#{id}.json"
    {:ok, data} = get_object(backend, key)
    corrupted = data |> JSON.decode!() |> mutation.() |> JSON.encode!()
    :ok = put_object(backend, key, corrupted, "application/json")
    corrupted
  end

  defp state, do: Application.fetch_env!(:gsmlg_storage, :catalog_test_state)
end
