defmodule GSMLG.GaoNote.Sync.Engine do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote.{Attachment, Attachments, Audit, Label, LabelSetting, Note}
  alias GSMLG.GaoNote.Sync.{Objects, Peers, Protocol, Snapshot, Store}
  alias GSMLG.Repo

  @limit 536_870_912

  def seed(peer, reconcile) do
    ids = Repo.all(from(n in Note, order_by: n.id, select: n.id))

    Enum.reduce_while(ids, :ok, fn id, :ok ->
      result =
        Store.transaction(fn ->
          lock_note(id)

          case capture(id, peers: [peer], historical: true, reconcile: reconcile) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, :ok} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def capture(note_id, opts \\ []) do
    peers = Keyword.get_lazy(opts, :peers, &Peers.selected/0)

    cond do
      peers == [] -> :ok
      not Repo.in_transaction?() -> {:error, :transaction_required}
      true -> capture_selected(note_id, peers, opts)
    end
  end

  defp capture_selected(id, peers, opts) do
    with {:ok, built} <- Snapshot.build(id) do
      old = Store.get("head", id)
      purge = opts[:kind] == :purge
      snapshot = if purge, do: nil, else: built.snapshot
      hash = Protocol.snapshot_hash(snapshot)

      version =
        cond do
          (not purge and old) && old["hash"] == hash -> old["version"]
          Keyword.get(opts, :historical, false) and is_nil(old) -> historical(built.snapshot)
          true -> Store.tick(if(old, do: old["version"]))
        end

      head = %{
        "snapshot" => snapshot,
        "hash" => hash,
        "version" => version,
        "objects" => if(purge, do: %{}, else: built.objects)
      }

      Store.put("head", id, head, nil, id)

      Enum.each(peers, fn peer ->
        reconcile = Keyword.get(opts, :reconcile, false) or scope_pending?(peer, id)
        capture_peer(peer, id, head, built.snapshot, Keyword.put(opts, :reconcile, reconcile))
        mark_scope(peer, id)
      end)

      :ok
    else
      {:error, :not_found} -> :ok
      {:error, _} = error -> error
    end
  end

  defp capture_peer(peer, id, head, matching_snapshot, opts) do
    member = Store.get("member", id, peer.id)
    selected = Peers.matches?(matching_snapshot, peer.selectors)
    attached = not is_nil(member) and member["attached"]
    purge = opts[:kind] == :purge

    suppress =
      not is_nil(member) and not attached and member["selected"] and
        not Keyword.get(opts, :reconcile, false) and not purge

    cond do
      purge and not attached ->
        if member, do: put_member(peer, id, Map.put(member, "selected", false))

      suppress or (not selected and not attached) ->
        if member, do: put_member(peer, id, Map.put(member, "selected", selected))

      true ->
        {kind, generation, control} =
          cond do
            purge ->
              {"purge", member["event"]["generation"], member["event"]["control"]}

            selected and attached ->
              kind = if member["event"]["kind"] == "attach", do: "attach", else: "snapshot"
              {kind, member["event"]["generation"], member["event"]["control"]}

            selected ->
              observed =
                if member,
                  do: latest_hlc([head["version"], member["event"]["control"]]),
                  else: head["version"]

              generation = Store.tick(observed)
              {"attach", generation, generation}

            true ->
              {"detach", member["event"]["generation"], Store.tick(member["event"]["control"])}
          end

        unchanged =
          not is_nil(member) and member["event"]["kind"] == kind and
            member["event"]["version"] == head["version"] and
            member["event"]["snapshot_hash"] == head["hash"]

        unless unchanged do
          event = event(id, head, kind, generation, control)

          updated = %{
            "attached" => selected and not purge,
            "authorized" => true,
            "selected" => selected and not purge,
            "event" => event,
            "objects" => head["objects"]
          }

          # A purge remains an active tombstone until an explicit newer attach.
          updated = if purge, do: Map.put(updated, "attached", true), else: updated
          put_member(peer, id, updated)
          queue(peer, event, head["objects"])
        end
    end
  end

  def inventory(peer) do
    Store.transaction(fn ->
      Peers.current!(peer)
      members = Store.list("member", peer.id)
      candidates = Repo.all(from(n in Note, select: n.id))
      (candidates ++ Enum.map(members, & &1.note_id)) |> Enum.uniq() |> Enum.sort()
    end)
  end

  def pending_ids(peer), do: session_ids(peer, "pending")

  defp session_ids(peer, kind) do
    Store.transaction(fn ->
      Peers.current!(peer)
      Objects.renew_leases(peer)

      Store.list(kind, peer.id)
      |> Enum.reject(fn r ->
        rejected?(Store.get("member", r.note_id, peer.id), r.data["event"])
      end)
      |> Enum.map(& &1.note_id)
    end)
  end

  def checkout(peer, id) do
    Store.transaction(fn ->
      current = Peers.current!(peer)
      note = lock_note(id)
      member = Store.get("member", id, peer.id)

      if not is_nil(note) and
           ((not is_nil(member) and member["authorized"] == true) or note_selected?(note, current)) do
        case capture(id, peers: [current], historical: true) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end
      end

      member = Store.get("member", id, peer.id)
      pending = Store.get("pending", id, peer.id)
      source = pending || member

      if is_nil(source) or rejected?(member, source["event"]) do
        :empty
      else
        event = source["event"]

        aggregate =
          byte_size(Jason.encode!(event)) +
            Enum.reduce(
              (event["snapshot"] || %{})["attachments"] || [],
              0,
              &(&1["size_bytes"] + &2)
            )

        if aggregate > current.max_blob_bytes or aggregate > @limit, do: Repo.rollback(:too_large)
        lease_id = Ecto.UUID.generate()

        data = %{
          "event" => event,
          "objects" => source["objects"],
          "session_id" => peer.session_id,
          "expires_at" => Objects.lease_expires_at()
        }

        owner = Store.put("lease", lease_id, data, peer.id, id)
        Objects.set(owner, source["objects"])
        {:ok, %{lease_id: lease_id, event: event, objects: source["objects"]}}
      end
    end)
    |> Store.unwrap()
  end

  def ack(peer, descriptor, lease_id) do
    Store.transaction(fn ->
      Peers.current!(peer)

      case Store.get("lease", lease_id, peer.id) do
        nil ->
          unless Store.get("ack", lease_id, peer.id) == descriptor,
            do: Repo.rollback(:ack_mismatch)

        lease ->
          unless live_lease?(lease) and lease["session_id"] == peer.session_id and
                   Protocol.ack(lease["event"]) == descriptor,
                 do: Repo.rollback(:ack_mismatch)

          id = descriptor["note_id"]

          case Store.get("pending", id, peer.id) do
            %{"event" => event} ->
              if Protocol.ack(event) == descriptor, do: Store.delete("pending", id, peer.id)

            nil ->
              :ok
          end

          member = Store.get("member", id, peer.id)

          if member && Protocol.ack(member["event"]) == descriptor do
            updated = retire_control(member)
            put_member(peer, id, updated)
          end

          Store.put("ack", lease_id, descriptor, peer.id, id)
          Store.delete("lease", lease_id, peer.id)
      end

      :ok
    end)
    |> Store.unwrap()
  end

  def reject(peer, rejection, lease_id) do
    Store.transaction(fn ->
      Peers.current!(peer)
      lease = Store.get("lease", lease_id, peer.id) || Repo.rollback(:rejection_mismatch)

      unless Protocol.exact_keys?(rejection, ~w(code event_id note_id reason)) and
               rejection["code"] == "note_rejected" and
               rejection["reason"] in ["validation_failed", "catalog_conflict"] and
               rejection["event_id"] == lease["event"]["event_id"] and
               rejection["note_id"] == lease["event"]["note_id"] and
               live_lease?(lease) and lease["session_id"] == peer.session_id,
             do: Repo.rollback(:rejection_mismatch)

      id = rejection["note_id"]
      member = Store.get("member", id, peer.id)

      if member && member["event"]["event_id"] == rejection["event_id"] do
        put_member(
          peer,
          id,
          Map.merge(member, %{
            "rejected_event_id" => rejection["event_id"],
            "rejected_reason" => rejection["reason"]
          })
        )
      end

      Store.delete("lease", lease_id, peer.id)
      :ok
    end)
    |> Store.unwrap()
  end

  def retry(peer_id) do
    Store.transaction(fn ->
      Enum.each(Store.list("member", peer_id), fn r ->
        Store.put(
          "member",
          r.note_id,
          Map.drop(r.data, ["rejected_event_id", "rejected_reason"]),
          peer_id,
          r.note_id
        )
      end)

      :ok
    end)
    |> Store.unwrap()
  end

  def release_lease(peer, lease_id) do
    Store.transaction(fn ->
      case Store.get("lease", lease_id, peer.id) do
        %{"session_id" => token} when token == peer.session_id ->
          Store.delete("lease", lease_id, peer.id)

        _ ->
          :ok
      end

      :ok
    end)
    |> Store.unwrap()
  end

  def release_session(peer) do
    Store.transaction(fn ->
      Store.list("lease", peer.id)
      |> Enum.each(fn r ->
        if r.data["session_id"] == peer.session_id, do: Repo.delete!(r)
      end)

      :ok
    end)
    |> Store.unwrap()
  end

  def apply(peer, event, bytes) do
    with :ok <- Protocol.validate_event(event),
         :ok <- validate_bytes(event, bytes),
         :ok <- authorized_snapshot(peer, event),
         {:ok, staged} <- prepare(event, bytes, peer.actor_id) do
      try do
        Store.transaction(fn ->
          current = Peers.current!(peer)
          note = lock_note(event["note_id"])
          authorize_local_note!(current, note)
          apply_locked(current, event, staged)
          {:ok, Protocol.ack(event)}
        end)
        |> Store.unwrap()
      after
        cleanup_staging(staged)
      end
    else
      {:error, :validation_failed} -> {:error, {:note_rejected, "validation_failed"}}
      {:error, _} = error -> error
    end
  end

  defp apply_locked(peer, event, staged) do
    id = event["note_id"]
    digest = Protocol.sha256(Protocol.canonical_json(event))

    case Store.get("received", event["event_id"], peer.id) do
      nil -> apply_new(peer, event, staged, digest)
      %{"event_hash" => ^digest} -> :ok
      _ -> Repo.rollback(:event_id_conflict)
    end

    # No reply is returned until this transaction, including the receipt, has committed.
    Store.put("received", event["event_id"], %{"event_hash" => digest}, peer.id, id)
  end

  defp apply_new(peer, %{"kind" => "fence"} = event, _staged, _digest) do
    id = event["note_id"]
    member = Store.get("member", id, peer.id)

    newer_local =
      member &&
        (compare(member["event"]["generation"], event["generation"]) == :gt or
           (member["event"]["generation"] == event["generation"] and
              compare(member["event"]["control"], event["control"]) == :gt))

    unless newer_local do
      Store.tick(event["control"])

      selected =
        case Snapshot.build(id) do
          {:ok, built} -> Peers.matches?(built.snapshot, peer.selectors)
          {:error, :not_found} -> false
          {:error, reason} -> Repo.rollback(reason)
        end

      put_member(peer, id, %{
        "attached" => false,
        "authorized" => selected or (not is_nil(member) and member["authorized"] == true),
        "selected" => selected,
        "event" => event,
        "objects" => %{}
      })

      mark_scope(peer, id)
      clear_older_pending(peer, event, true)
    end
  end

  defp apply_new(peer, event, staged, _digest) do
    id = event["note_id"]
    head = ensure_head(id)
    member = Store.get("member", id, peer.id)

    if head && head["version"] == event["version"] && head["hash"] != event["snapshot_hash"],
      do: Repo.rollback(:version_conflict)

    independent_detach =
      not is_nil(member) and not member["attached"] and event["kind"] == "detach" and
        not is_nil(head) and head["version"] != member["event"]["version"]

    if allowed?(member, event) and not independent_detach do
      case authorized_snapshot(peer, event) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      Store.tick(latest_hlc([event["version"], event["generation"], event["control"]]))
      winning = is_nil(head) or compare(event["version"], head["version"]) == :gt

      winner =
        if winning do
          objects =
            if head && head["hash"] == event["snapshot_hash"] do
              head["objects"]
            else
              apply_content(peer, event, staged)
            end

          remote = %{
            "snapshot" => event["snapshot"],
            "version" => event["version"],
            "hash" => event["snapshot_hash"],
            "objects" => objects
          }

          Store.put("head", id, remote, nil, id)
          remote
        else
          head
        end

      attached = event["kind"] != "detach"
      selected = Peers.matches?(winner["snapshot"], peer.selectors)

      response_event =
        if compare(winner["version"], event["version"]) == :gt do
          kind =
            cond do
              is_nil(winner["snapshot"]) and not attached -> "fence"
              is_nil(winner["snapshot"]) -> "purge"
              not attached -> "detach"
              event["kind"] == "attach" -> "attach"
              true -> "snapshot"
            end

          event(id, winner, kind, event["generation"], event["control"])
        else
          if event["kind"] == "detach",
            do:
              Map.merge(event, %{
                "event_id" => Ecto.UUID.generate(),
                "kind" => "fence",
                "snapshot" => nil
              }),
            else: event
        end

      member_objects = if response_event["snapshot"], do: winner["objects"], else: %{}

      put_member(peer, id, %{
        "attached" => attached,
        "authorized" => true,
        "selected" => selected,
        "event" => response_event,
        "objects" => member_objects
      })

      mark_scope(peer, id)

      if compare(winner["version"], event["version"]) == :gt do
        queue(peer, response_event, member_objects)
      else
        clear_older_pending(peer, event, not attached)
      end

      if winning do
        opts = if event["kind"] == "purge", do: [kind: :purge], else: []

        Peers.selected()
        |> Enum.reject(&(&1.id == peer.id))
        |> Enum.each(fn other ->
          capture_peer(
            other,
            id,
            winner,
            winner["snapshot"],
            Keyword.put(opts, :reconcile, scope_pending?(other, id))
          )

          mark_scope(other, id)
        end)
      end
    end
  end

  defp allowed?(nil, event), do: event["kind"] == "attach"

  defp allowed?(member, %{"kind" => "attach"} = event) do
    compare(event["generation"], member["event"]["generation"]) == :gt or
      (event["generation"] == member["event"]["generation"] and member["attached"] and
         compare(event["control"], member["event"]["control"]) != :lt)
  end

  defp allowed?(member, event) do
    member["authorized"] == true and (member["attached"] or event["kind"] == "detach") and
      event["generation"] == member["event"]["generation"] and
      compare(event["control"], member["event"]["control"]) != :lt
  end

  defp apply_content(peer, %{"snapshot" => nil} = event, _staged) do
    case Repo.get(Note, event["note_id"]) do
      nil ->
        :ok

      note ->
        ids =
          Repo.all(from(a in Attachment, where: a.note_id == ^note.id, select: a.storage_file_id))

        Repo.delete!(note)

        case Attachments.schedule_purges(ids) do
          {:ok, _} -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        audit!(peer, event, "purge")
    end

    %{}
  end

  defp apply_content(peer, event, staged) do
    id = event["note_id"]
    snapshot = event["snapshot"]
    settings = reconcile_catalog!(snapshot["labels"])
    old = Repo.get(Note, id)
    revision = if old, do: old.revision + 1, else: 1
    note = old || %Note{id: id}

    changes = %{
      title: snapshot["title"],
      content: snapshot["content"],
      created_at: timestamp!(snapshot["created_at"]),
      updated_at: timestamp!(snapshot["updated_at"]),
      deleted_at: timestamp!(snapshot["deleted_at"]),
      revision: revision
    }

    changeset =
      note
      |> Note.changeset(changes)
      |> Ecto.Changeset.change(Map.drop(changes, [:title, :content]))
      |> Ecto.Changeset.force_change(:updated_at, changes.updated_at)

    case Repo.insert_or_update(changeset) do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback({:note_rejected, "validation_failed"})
    end

    Repo.delete_all(from(l in Label, where: l.note_id == ^id))

    Enum.each(snapshot["labels"], fn label ->
      changeset =
        %Label{}
        |> Label.changeset(%{
          note_id: id,
          label_setting_id: Map.fetch!(settings, label["key"]).id,
          value: label["value"],
          status: "valid",
          errors: []
        })
        |> Ecto.Changeset.force_change(:value, label["value"])

      case Repo.insert(changeset) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback({:note_rejected, "validation_failed"})
      end
    end)

    case Attachments.reconcile(id, staged.plan) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end

    Enum.each(staged.identities, fn {local_id, public_id} ->
      Repo.update_all(from(a in Attachment, where: a.id == ^local_id), set: [api_id: public_id])
    end)

    built =
      case Snapshot.build(id) do
        {:ok, built} -> built
        {:error, reason} -> Repo.rollback(reason)
      end

    unless Protocol.snapshot_hash(built.snapshot) == event["snapshot_hash"],
      do: Repo.rollback({:note_rejected, "validation_failed"})

    audit!(peer, event, if(old, do: "update", else: "create"))
    built.objects
  end

  defp reconcile_catalog!(labels) do
    Enum.reduce(labels, %{}, fn label, acc ->
      key = label["key"]
      type = if label["value_type"] == "datetime", do: "date-time", else: label["value_type"]

      changeset =
        %LabelSetting{}
        |> LabelSetting.changeset(%{
          name: key,
          value_type: type,
          description: label["description"]
        })
        |> Ecto.Changeset.force_change(:name, key)

      case Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:name]) do
        {:ok, _} -> :ok
        {:error, _} -> Repo.rollback({:note_rejected, "validation_failed"})
      end

      setting = Repo.one!(from(s in LabelSetting, where: s.name == ^key, lock: "FOR SHARE"))

      unless setting.value_type == type and setting.description == label["description"],
        do: Repo.rollback({:note_rejected, "catalog_conflict"})

      Map.put(acc, key, setting)
    end)
  end

  defp prepare(%{"snapshot" => nil}, _bytes, _actor), do: {:ok, %{plan: nil, identities: %{}}}

  defp prepare(event, bytes, actor) do
    id = event["note_id"]
    current = Repo.all(from(a in Attachment, where: a.note_id == ^id))

    {inputs, identities} =
      Enum.map_reduce(event["snapshot"]["attachments"], %{}, fn descriptor, identities ->
        existing = Enum.find(current, &((&1.api_id || &1.id) == descriptor["id"]))
        local_id = if existing, do: existing.id, else: "sync:" <> Ecto.UUID.generate()

        {%{
           id: local_id,
           path: descriptor["path"],
           mime: descriptor["mime"],
           description: descriptor["description"],
           content: Map.fetch!(bytes, descriptor["id"])
         }, Map.put(identities, local_id, descriptor["id"])}
      end)

    case Attachments.prepare_sync(id, inputs, actor) do
      {:ok, plan} ->
        {:ok, %{plan: plan, identities: identities}}

      {:error, {:attachment, %{code: :mime_mismatch}}} ->
        {:error, :validation_failed}

      {:error, {:attachment, %{code: :staging_failed, reason: {code, _, _}}}}
      when code in [:content_type_not_allowed, :file_too_large] ->
        {:error, :validation_failed}

      {:error, _} = error ->
        error
    end
  end

  defp cleanup_staging(%{plan: nil}), do: :ok

  defp cleanup_staging(%{plan: plan}) do
    used =
      Repo.all(
        from(a in Attachment,
          where: a.storage_file_id in ^Enum.map(plan.staged_files, & &1.id),
          select: a.storage_file_id
        )
      )
      |> MapSet.new()

    Attachments.cleanup(%{
      staged_files: Enum.reject(plan.staged_files, &MapSet.member?(used, &1.id))
    })
  end

  defp validate_bytes(event, bytes) when is_map(bytes) do
    manifest = if event["snapshot"], do: event["snapshot"]["attachments"], else: []
    ids = Enum.map(manifest, & &1["id"]) |> Enum.sort()

    aggregate =
      byte_size(Jason.encode!(event)) + Enum.reduce(manifest, 0, &(&1["size_bytes"] + &2))

    if Enum.sort(Map.keys(bytes)) == ids and aggregate <= @limit and
         Enum.all?(manifest, fn d ->
           value = bytes[d["id"]]

           is_binary(value) and byte_size(value) == d["size_bytes"] and
             Protocol.sha256(value) == d["checksum_sha256"]
         end),
       do: :ok,
       else: {:error, :validation_failed}
  end

  defp validate_bytes(_, _), do: {:error, :validation_failed}

  defp authorized_snapshot(peer, %{"kind" => kind, "snapshot" => snapshot})
       when kind in ["attach", "snapshot"] do
    if Peers.matches?(snapshot, peer.selectors), do: :ok, else: {:error, :unauthorized}
  end

  defp authorized_snapshot(_, _), do: :ok

  defp authorize_local_note!(_peer, nil), do: :ok

  defp authorize_local_note!(peer, note) do
    member = Store.get("member", note.id, peer.id)

    unless (not is_nil(member) and member["authorized"] == true) or note_selected?(note, peer),
      do: Repo.rollback(:unauthorized)
  end

  defp live_lease?(lease),
    do: is_integer(lease["expires_at"]) and lease["expires_at"] > System.system_time(:millisecond)

  defp note_selected?(note, peer) do
    labels = Repo.preload(note, labels: :label_setting).labels

    snapshot = %{
      "labels" =>
        Enum.map(labels, fn l ->
          %{
            "key" => l.label_setting.name,
            "value" => l.value || "",
            "value_type" => l.label_setting.value_type
          }
        end)
    }

    Peers.matches?(snapshot, peer.selectors)
  end

  defp ensure_head(id) do
    case Store.get("head", id) do
      nil ->
        case Snapshot.build(id) do
          {:ok, built} ->
            head = %{
              "version" => historical(built.snapshot),
              "hash" => Protocol.snapshot_hash(built.snapshot),
              "snapshot" => built.snapshot,
              "objects" => built.objects
            }

            Store.put("head", id, head, nil, id)
            head

          {:error, :not_found} ->
            nil

          {:error, reason} ->
            Repo.rollback(reason)
        end

      head ->
        head
    end
  end

  defp historical(snapshot) do
    %{
      "millis" =>
        max(snapshot["updated_at"], snapshot["deleted_at"] || snapshot["updated_at"]) * 1000,
      "counter" => 0,
      "node_id" => Store.node()["node_id"]
    }
  end

  defp event(id, head, kind, generation, control) do
    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => id,
      "generation" => generation,
      "control" => control,
      "version" => head["version"],
      "kind" => kind,
      "snapshot" => if(kind == "fence", do: nil, else: head["snapshot"]),
      "snapshot_hash" => head["hash"]
    }
  end

  defp put_member(peer, id, member) do
    owner = Store.put("member", id, member, peer.id, id)
    Objects.set(owner, member["objects"])
  end

  defp scope_pending?(peer, id),
    do:
      not is_nil(peer.scope_id) and
        Store.get("reconciled", id, peer.id) != %{"scope_id" => peer.scope_id}

  defp mark_scope(%{scope_id: nil}, _id), do: :ok

  defp mark_scope(peer, id),
    do: Store.put("reconciled", id, %{"scope_id" => peer.scope_id}, peer.id, id)

  defp queue(peer, event, objects) do
    owner =
      Store.put(
        "pending",
        event["note_id"],
        %{"event" => event, "objects" => objects},
        peer.id,
        event["note_id"]
      )

    Objects.set(owner, objects)
  end

  defp clear_older_pending(peer, event, closed) do
    case Store.get("pending", event["note_id"], peer.id) do
      %{"event" => pending} ->
        if compare(pending["generation"], event["generation"]) != :gt and
             (closed or compare(pending["version"], event["version"]) != :gt),
           do: Store.delete("pending", event["note_id"], peer.id)

      nil ->
        :ok
    end
  end

  defp retire_control(%{"event" => %{"kind" => "attach"} = event} = member),
    do:
      Map.put(
        member,
        "event",
        Map.merge(event, %{"kind" => "snapshot", "event_id" => Ecto.UUID.generate()})
      )

  defp retire_control(%{"event" => %{"kind" => "detach"} = event} = member),
    do:
      Map.merge(member, %{
        "event" =>
          Map.merge(event, %{
            "kind" => "fence",
            "snapshot" => nil,
            "event_id" => Ecto.UUID.generate()
          }),
        "objects" => %{}
      })

  defp retire_control(member), do: member
  defp rejected?(nil, _), do: false
  defp rejected?(member, event), do: member["rejected_event_id"] == event["event_id"]
  defp compare(left, right), do: Protocol.compare_hlc(left, right)

  defp latest_hlc(stamps),
    do:
      Enum.reduce(stamps, fn stamp, latest ->
        if compare(stamp, latest) == :gt, do: stamp, else: latest
      end)

  defp lock_note(id) do
    Store.lock("note", id)
    Repo.one(from(n in Note, where: n.id == ^id, lock: "FOR UPDATE"))
  end

  defp timestamp!(nil), do: nil

  defp timestamp!(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, value} -> %{value | microsecond: {0, 6}}
      {:error, _} -> Repo.rollback({:note_rejected, "validation_failed"})
    end
  end

  defp audit!(peer, event, action) do
    case Audit.log(
           action,
           "note",
           event["note_id"],
           event["note_id"],
           %{id: peer.actor_id, source: "note_sync"},
           %{"event_id" => event["event_id"], "peer_id" => peer.id}
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end
end
