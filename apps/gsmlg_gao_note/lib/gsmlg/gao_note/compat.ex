defmodule GSMLG.GaoNote.Compat do
  @moduledoc "Agent Note domain compatibility backed by the shared GaoNote records."
  import Ecto.Query
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Attachments, Audit, LabelSetting, Note}
  alias GSMLG.GaoNote.Compat.{Catalog, ContentPatch, LabelSelector}
  alias GSMLG.Repo

  def get_note(id), do: GaoNote.get_note(id)
  def get_note_metadata(id), do: get_note(id)

  def list_notes(opts \\ %{}), do: list_state(opts, :active)
  def list_deleted_notes(opts \\ %{}), do: matching_notes(opts, :deleted)

  def count_notes(opts \\ %{}) do
    with {:ok, notes} <- matching_notes(opts, :active), do: {:ok, length(notes)}
  end

  defp list_state(opts, state) do
    with {:ok, notes} <- matching_notes(opts, state) do
      limit = field(opts, :limit, 10) |> integer(10) |> max(0) |> min(1000)
      offset = field(opts, :offset, 0) |> integer(0) |> max(0)
      {:ok, notes |> Enum.drop(offset) |> Enum.take(limit)}
    end
  end

  defp matching_notes(opts, state) do
    with {:ok, selectors} <- LabelSelector.parse(field(opts, :label, "")) do
      query =
        if state == :active,
          do: from(n in Note, where: is_nil(n.deleted_at)),
          else: from(n in Note, where: not is_nil(n.deleted_at))

      query =
        if state == :deleted,
          do: order_by(query, [n], desc: n.deleted_at, asc: n.id),
          else: order_by(query, [n], desc: n.created_at, asc: n.id)

      notes =
        query
        |> preload(labels: :label_setting, attachments: :storage_file)
        |> Repo.all()

      {:ok,
       Enum.filter(
         notes,
         &LabelSelector.matches_all?(
           Enum.map(&1.labels, fn label ->
             %{
               key: label.label_setting.name,
               value: label.value || "",
               value_type: label.label_setting.value_type
             }
           end),
           selectors
         )
       )}
    else
      {:error, message} -> {:error, {:invalid_input, message}}
    end
  end

  def save_note(attrs, actor) when is_map(attrs) do
    attrs = atom_attrs(attrs)
    id = Ecto.UUID.generate()

    with :ok <- required(attrs, [:title, :content]),
         {:ok, labels} <- Catalog.normalize(Map.get(attrs, :labels, [])),
         :ok <- Catalog.validate_values(labels),
         {:ok, inputs, identities} <- attachment_inputs(id, Map.get(attrs, :attachments, [])),
         {:ok, plan} <- Attachments.prepare(id, inputs, Audit.actor_id(actor)) do
      Attachments.transact(plan, fn ->
        with {:ok, note} <- %Note{id: id} |> Note.create_changeset(attrs) |> Repo.insert(),
             :ok <- Catalog.replace(note, labels),
             {:ok, _} <- Attachments.reconcile(id, plan),
             :ok <- persist_identities(identities),
             {:ok, _} <- Audit.log("create", "note", id, id, actor, %{"title" => note.title}) do
          get_note(id)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def save_note(_, _), do: invalid("note must be an object")

  def replace_note(id, expected_revision, attrs, actor) when is_map(attrs) do
    attrs = atom_attrs(attrs)

    with :ok <- required(attrs, [:title, :content, :labels, :attachments]),
         true <- is_binary(Map.get(attrs, :content)) do
      patch_note(id, expected_revision, attrs, actor)
    else
      false -> invalid("content must be a string")
      error -> error
    end
  end

  def replace_note(_, _, _, _), do: invalid("note must be an object")

  def patch_note(id, revision, attrs, actor) when is_map(attrs) do
    attrs = atom_attrs(attrs)

    with :ok <- positive_revision(revision),
         :ok <- patch_shape(attrs),
         %Note{} = note <- get_note(id),
         :ok <- ensure_revision(note, revision),
         {:ok, attrs} <- resolve_content(attrs, note.content),
         {:ok, labels} <- Catalog.normalize(Map.get(attrs, :labels, Catalog.pairs(note))),
         :ok <- Catalog.validate_values(labels),
         {:ok, inputs, identities} <-
           attachment_inputs(id, Map.get(attrs, :attachments, retained_inputs(note))),
         {:ok, plan} <- Attachments.prepare(id, inputs, Audit.actor_id(actor)) do
      Attachments.transact(plan, fn ->
        with {:ok, locked} <- lock_note(id, :active),
             :ok <- ensure_revision(locked, revision),
             {:ok, attachments_changed} <-
               if(Map.has_key?(attrs, :attachments),
                 do: Attachments.changed?(plan),
                 else: {:ok, false}
               ) do
          changeset = Note.changeset(locked, Map.take(attrs, [:title, :content]))
          labels_changed = Catalog.pairs(locked) != labels
          changed = map_size(changeset.changes) > 0 or labels_changed or attachments_changed

          changeset =
            if changed,
              do: Ecto.Changeset.put_change(changeset, :revision, locked.revision + 1),
              else: changeset

          with {:ok, _updated} <- Repo.update(changeset),
               :ok <- if(labels_changed, do: Catalog.replace(locked, labels), else: :ok),
               {:ok, _} <-
                 if(attachments_changed, do: Attachments.reconcile(id, plan), else: {:ok, []}),
               :ok <- persist_identities(identities),
               {:ok, _} <-
                 if(changed,
                   do: Audit.log("update", "note", id, id, actor, %{"title" => locked.title}),
                   else: {:ok, nil}
                 ) do
            %{note: get_note(id), changed: changed}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> cleanup_noop(plan)
    else
      nil -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def patch_note(_, _, _, _), do: invalid("patch must be an object")

  def delete_note(id, revision, actor), do: lifecycle(id, revision, actor, :delete)
  def restore_note(id, revision, actor), do: lifecycle(id, revision, actor, :restore)
  def permanently_delete_note(id, revision, actor), do: lifecycle(id, revision, actor, :purge)

  defp lifecycle(id, revision, actor, action) do
    with :ok <- positive_revision(revision) do
      Repo.transaction(fn ->
        state = if action == :delete, do: :active, else: :deleted

        with {:ok, note} <- lock_note(id, state),
             :ok <- ensure_revision(note, revision),
             {:ok, updated} <-
               (case action do
                  :delete -> GaoNote.delete_note(note, actor)
                  :restore -> GaoNote.restore_note(note, actor)
                  :purge -> GaoNote.permanently_delete_note(note, actor)
                end) do
          %{note: updated, changed: true}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def list_label_keys, do: {:ok, LabelSetting |> order_by([s], asc: s.name) |> Repo.all()}

  def define_label_key(key, attrs, actor \\ nil) do
    attrs = if is_binary(attrs), do: %{description: attrs}, else: catalog_attrs(attrs)

    with :ok <- Catalog.validate_key(key) do
      changeset =
        LabelSetting.changeset(%LabelSetting{}, Map.put(attrs, :name, key))
        |> Ecto.Changeset.put_change(:name, key)

      changeset |> Repo.insert() |> audit_catalog("create", actor)
    end
  end

  def update_label_key(key, attrs, actor \\ nil) do
    attrs = if is_binary(attrs), do: %{description: attrs}, else: catalog_attrs(attrs)

    case Repo.get_by(LabelSetting, name: key) do
      nil ->
        {:ok, nil}

      setting ->
        GaoNote.update_label_setting(setting, Map.delete(attrs, :name), actor)
        |> catalog_missing_noop()
    end
  end

  def delete_label_key(key, actor \\ nil) do
    case Repo.get_by(LabelSetting, name: key) do
      nil -> {:ok, nil}
      setting -> GaoNote.delete_label_setting(setting, actor) |> catalog_missing_noop()
    end
  end

  defp catalog_missing_noop({:error, :catalog_not_found}), do: {:ok, nil}
  defp catalog_missing_noop(result), do: result

  def get_note_attachment_content(note_id, api_id) do
    case attachment_by_api_id(note_id, api_id) do
      nil -> {:error, :not_found}
      attachment -> Attachments.get_with_content(note_id, attachment.id)
    end
  end

  def put_note_attachment(note_id, api_id, revision, attrs, actor) when is_map(attrs) do
    with :ok <- positive_revision(revision),
         %Note{} = note <- get_note(note_id),
         :ok <- ensure_revision(note, revision),
         {:ok, api_id} <- canonical_api_id(api_id) do
      attrs = atom_attrs(attrs) |> Map.put(:id, api_id)
      existing = Enum.find(note.attachments, &(&1.api_id == api_id))

      with :ok <- immutable_path(existing, attrs),
           {:ok, inputs, identities} <-
             attachment_inputs(
               note_id,
               Enum.reject(retained_inputs(note), &(field(&1, :id) == api_id)) ++ [attrs]
             ),
           {:ok, plan} <- Attachments.prepare(note_id, inputs, Audit.actor_id(actor)) do
        Attachments.transact(plan, fn ->
          with {:ok, locked} <- lock_note(note_id, :active),
               :ok <- ensure_revision(locked, revision),
               {:ok, _} <- Attachments.reconcile(note_id, plan),
               :ok <- persist_identities(identities),
               {:ok, updated} <- GaoNote.advance_revision(locked),
               {:ok, _} <-
                 Audit.log("update", "note", note_id, note_id, actor, %{
                   "fields" => ["attachments"]
                 }) do
            %{
              attachment: attachment_by_api_id(note_id, api_id) |> Repo.preload(:storage_file),
              revision: updated.revision,
              created: is_nil(existing)
            }
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def put_note_attachment(_, _, _, _, _), do: invalid("attachment must be an object")

  def delete_note_attachment(note_id, api_id, revision, actor) do
    with :ok <- positive_revision(revision), {:ok, api_id} <- canonical_api_id(api_id) do
      Repo.transaction(fn ->
        with {:ok, note} <- lock_note(note_id, :active), :ok <- ensure_revision(note, revision) do
          case attachment_by_api_id(note_id, api_id) do
            nil ->
              %{revision: note.revision, changed: false}

            attachment ->
              case GaoNote.delete_attachment(note_id, attachment.id, actor) do
                {:ok, _} -> %{revision: get_note(note_id).revision, changed: true}
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def bulk_update_note_labels(attrs, actor), do: GSMLG.GaoNote.Compat.Bulk.selector(attrs, actor)
  def batch_update_note_labels(attrs, actor), do: GSMLG.GaoNote.Compat.Bulk.labels(attrs, actor)

  def batch_delete_notes(attrs, actor),
    do: GSMLG.GaoNote.Compat.Bulk.lifecycle(attrs, actor, :delete)

  def batch_permanently_delete_notes(attrs, actor),
    do: GSMLG.GaoNote.Compat.Bulk.lifecycle(attrs, actor, :purge)

  def restore_notes(attrs, actor), do: GSMLG.GaoNote.Compat.Bulk.lifecycle(attrs, actor, :restore)

  def lock_note(id, state) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      query =
        if state == :active,
          do: from(n in Note, where: is_nil(n.deleted_at)),
          else: from(n in Note, where: not is_nil(n.deleted_at))

      case query |> where([n], n.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
        nil -> {:error, :not_found}
        note -> {:ok, Repo.preload(note, labels: :label_setting, attachments: :storage_file)}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  def ensure_revision(note, revision) do
    if note.revision == revision,
      do: :ok,
      else:
        {:error,
         {:revision_conflict,
          %{note_id: note.id, expected_revision: revision, current_revision: note.revision}}}
  end

  def positive_revision(value)
      when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807,
      do: :ok

  def positive_revision(_), do: invalid("expected_revision must be a positive integer")

  def attachment_by_api_id(note_id, api_id) do
    with {:ok, id} <- Ecto.UUID.cast(note_id), {:ok, api_id} <- canonical_api_id(api_id) do
      Repo.get_by(Attachment, note_id: id, api_id: api_id)
    else
      _ -> nil
    end
  end

  defp attachment_inputs(note_id, raw) when is_list(raw) do
    Enum.reduce_while(raw, {:ok, [], %{}}, fn attrs, {:ok, inputs, identities} ->
      with true <- is_map(attrs), {:ok, api_id} <- canonical_api_id(field(attrs, :id)) do
        existing = attachment_by_api_id(note_id, api_id)
        id = if existing, do: existing.id, else: "compat:" <> Ecto.UUID.generate()

        if api_id in Map.values(identities) do
          {:halt, invalid("duplicate attachment id")}
        else
          {:cont,
           {:ok, [atom_attrs(attrs) |> Map.put(:id, id) | inputs],
            Map.put(identities, id, api_id)}}
        end
      else
        _ -> {:halt, invalid("invalid attachment")}
      end
    end)
    |> case do
      {:ok, inputs, identities} -> {:ok, Enum.reverse(inputs), identities}
      error -> error
    end
  end

  defp attachment_inputs(_, _), do: invalid("attachments must be an array")

  defp persist_identities(identities) do
    Enum.each(identities, fn {id, api_id} ->
      Repo.update_all(from(a in Attachment, where: a.id == ^id and a.api_id != ^api_id),
        set: [api_id: api_id]
      )
    end)

    :ok
  end

  defp retained_inputs(note),
    do:
      Enum.map(
        note.attachments,
        &%{id: &1.api_id, path: &1.path, mime: &1.mime, description: &1.description}
      )

  defp canonical_api_id(id) when is_binary(id) do
    if String.trim(id) == "",
      do: invalid("attachment id must not be blank"),
      else: {:ok, String.trim(id)}
  end

  defp canonical_api_id(_), do: invalid("attachment id must be a string")
  defp immutable_path(nil, _), do: :ok

  defp immutable_path(existing, attrs) do
    case Attachment.normalize_path(field(attrs, :path)) do
      {:ok, path} when path == existing.path -> :ok
      _ -> {:error, {:attachment_path_change, existing.api_id}}
    end
  end

  defp cleanup_noop({:ok, %{note: note}} = result, plan) do
    used = MapSet.new(note.attachments, & &1.storage_file_id)
    unused = Enum.reject(plan.staged_files, &MapSet.member?(used, &1.id))
    Attachments.cleanup(%{staged_files: unused})
    result
  end

  defp cleanup_noop(result, _), do: result

  defp resolve_content(attrs, current) do
    case Map.fetch(attrs, :content) do
      :error ->
        {:ok, attrs}

      {:ok, value} when is_binary(value) ->
        {:ok, attrs}

      {:ok, value} when is_map(value) ->
        cond do
          map_size(value) == 1 and is_binary(field(value, :replace)) ->
            {:ok, Map.put(attrs, :content, field(value, :replace))}

          map_size(value) == 1 and is_binary(field(value, :apply_patch)) ->
            case ContentPatch.apply(current, field(value, :apply_patch)) do
              {:ok, content} -> {:ok, Map.put(attrs, :content, content)}
              {:error, message} -> {:error, {:patch_failed, message}}
            end

          true ->
            invalid("content must provide replace or apply_patch")
        end

      _ ->
        invalid("content must be a string or update object")
    end
  end

  defp patch_shape(attrs) do
    cond do
      map_size(attrs) == 0 ->
        invalid("patch must provide at least one field")

      Enum.any?(attrs, fn {_, value} -> is_nil(value) end) ->
        invalid("patch fields must not be null")

      true ->
        :ok
    end
  end

  defp required(attrs, keys) do
    if Enum.all?(keys, &Map.has_key?(attrs, &1)),
      do: :ok,
      else: invalid("missing required note field")
  end

  defp audit_catalog({:ok, setting}, action, actor) do
    Audit.log(action, "label_setting", setting.id, nil, actor, %{"name" => setting.name})
    {:ok, setting}
  end

  defp audit_catalog(error, _, _), do: error
  def field(map, key, default \\ nil)
  def field(map, key, default) when is_list(map), do: Keyword.get(map, key, default)

  def field(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  def field(_, _, default), do: default

  defp catalog_attrs(attrs) do
    attrs = atom_attrs(attrs)

    if Map.get(attrs, :value_type) == "datetime",
      do: Map.put(attrs, :value_type, "date-time"),
      else: attrs
  end

  defp atom_attrs(map) when is_map(map) do
    keys =
      ~w(title content labels attachments id path mime description content_base64 update_content selector set remove notes action type key value from_key value_type)a

    Enum.reduce(keys, %{}, fn key, acc ->
      cond do
        Map.has_key?(map, key) ->
          Map.put(acc, key, Map.fetch!(map, key))

        Map.has_key?(map, Atom.to_string(key)) ->
          Map.put(acc, key, Map.fetch!(map, Atom.to_string(key)))

        true ->
          acc
      end
    end)
  end

  defp integer(value, _) when is_integer(value), do: value

  defp integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> n
      _ -> default
    end
  end

  defp integer(_, default), do: default
  def invalid(message), do: {:error, {:invalid_input, message}}
end
