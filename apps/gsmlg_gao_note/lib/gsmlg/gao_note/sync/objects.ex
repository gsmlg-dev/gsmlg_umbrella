defmodule GSMLG.GaoNote.Sync.Objects do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote.Attachment
  alias GSMLG.GaoNote.Sync.{Pin, Record, Store}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @lease_millis 60_000

  def lease_expires_at, do: System.system_time(:millisecond) + @lease_millis

  def renew_leases(peer) do
    now = System.system_time(:millisecond)
    expires_at = now + @lease_millis
    updated_at = DateTime.utc_now()

    query =
      from(r in Record,
        where: r.kind == "lease" and r.peer_id == ^peer.id,
        where: fragment("?->>'session_id'", r.data) == ^peer.session_id
      )

    if Repo.exists?(
         from(r in query, where: fragment("(?->>'expires_at')::bigint <= ?", r.data, ^now))
       ),
       do: Repo.rollback(:lease_expired)

    Repo.update_all(
      from(r in query,
        where: fragment("(?->>'expires_at')::bigint > ?", r.data, ^now),
        update: [
          set: [
            data:
              fragment("jsonb_set(?, '{expires_at}', to_jsonb(?::bigint))", r.data, ^expires_at),
            updated_at: ^updated_at
          ]
        ]
      ),
      []
    )

    :ok
  end

  def lock_objects(ids) do
    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn id, :ok ->
      Store.lock("object", id)

      if Repo.exists?(
           from(file in StorageFile, where: file.id == ^id and file.status == "active")
         ),
         do: {:cont, :ok},
         else: {:halt, {:error, :object_unavailable}}
    end)
  end

  def with_object_lock(id, operation) do
    Store.transaction(fn ->
      Store.lock("object", id)
      operation.()
    end)
  end

  def referenced?(id) do
    # Callers hold the object lock. Conditional deletion serializes with renewal;
    # an expired read owner must not keep replaced objects pinned after a VM crash.
    owners = from(p in Pin, where: p.storage_file_id == ^id, select: p.owner_id)
    now = System.system_time(:millisecond)

    Repo.delete_all(
      from(r in Record,
        where: r.kind == "lease" and r.id in subquery(owners),
        where: fragment("(?->>'expires_at')::bigint <= ?", r.data, ^now)
      )
    )

    Repo.exists?(from(a in Attachment, where: a.storage_file_id == ^id)) or
      Repo.exists?(from(p in Pin, where: p.storage_file_id == ^id))
  end

  def set(owner_id, objects) do
    ids = Map.values(objects) |> Enum.uniq()

    case lock_objects(ids) do
      :ok ->
        Repo.delete_all(from(p in Pin, where: p.owner_id == ^owner_id))

        Enum.each(
          ids,
          &Repo.insert!(%Pin{owner_id: owner_id, storage_file_id: &1}, on_conflict: :nothing)
        )

        :ok

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end
end
