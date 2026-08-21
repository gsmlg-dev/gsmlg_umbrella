defmodule GSMLG.GaoNote.BatchActions do
  @moduledoc """
  Applies atomic note and label mutations with deterministic row locking.
  """

  import Ecto.Query, warn: false

  alias GSMLG.GaoNote.{Attachments, Audit, Label, LabelSetting, LabelValue, Note}
  alias GSMLG.Repo

  @max_active_selection 100
  @max_deleted_selection 200

  def mutate_note_labels(note_ids, operation, actor) do
    Repo.transaction(fn ->
      with {:ok, operation} <- normalize_operation(operation),
           {:ok, note_ids} <- normalize_note_ids(note_ids),
           {:ok, settings} <- lock_label_settings(operation),
           {:ok, operation} <- validate_values(operation, settings),
           {:ok, notes} <- lock_active_notes(note_ids),
           labels <- lock_labels(note_ids),
           {:ok, plan} <- plan(operation, notes, labels),
           :ok <- apply_changes(plan.changes),
           :ok <- audit_changes(plan.changes, operation.kind, actor) do
        selected = length(note_ids)
        changed = length(plan.changes)

        %{
          selected: selected,
          matched: plan.matched,
          changed: changed,
          unchanged: selected - changed
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def delete_notes(note_ids, actor) do
    Repo.transaction(fn ->
      with {:ok, note_ids} <- normalize_note_ids(note_ids, @max_active_selection),
           {:ok, notes} <- lock_active_notes(note_ids),
           deleted_at = DateTime.utc_now(),
           :ok <- soft_delete_notes(notes, deleted_at),
           :ok <- audit_deleted_notes(notes, deleted_at, actor) do
        %{selected: length(note_ids), deleted: length(notes)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def permanently_delete_notes(note_ids, actor) do
    Repo.transaction(fn ->
      with {:ok, note_ids} <- normalize_note_ids(note_ids, @max_deleted_selection),
           {:ok, notes} <- lock_deleted_notes(note_ids),
           notes = Repo.preload(notes, :attachments),
           storage_file_ids = storage_file_ids(notes),
           :ok <- schedule_purges(storage_file_ids),
           :ok <- purge_notes(notes),
           :ok <- audit_purged_notes(notes, actor) do
        %{selected: length(note_ids), purged: length(notes)}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp normalize_operation({:add, %{label_setting_id: id, value: value} = attrs})
       when map_size(attrs) == 2 do
    with {:ok, id} <- cast_operation_id(id) do
      {:ok, %{kind: :add, target_id: id, target_value: value}}
    end
  end

  defp normalize_operation(
         {:edit,
          %{
            match: %{label_setting_id: source_id, value: match_value} = match,
            replacement: %{label_setting_id: target_id, value: target_value} = replacement
          } = attrs}
       )
       when map_size(attrs) == 2 and map_size(match) == 2 and map_size(replacement) == 2 do
    with {:ok, source_id} <- cast_operation_id(source_id),
         {:ok, target_id} <- cast_operation_id(target_id),
         {:ok, match_value} <- normalize_match_value(match_value) do
      {:ok,
       %{
         kind: :edit,
         source_id: source_id,
         match_value: match_value,
         target_id: target_id,
         target_value: target_value
       }}
    end
  end

  defp normalize_operation(
         {:delete, %{match: %{label_setting_id: source_id, value: match_value} = match} = attrs}
       )
       when map_size(attrs) == 1 and map_size(match) == 2 do
    with {:ok, source_id} <- cast_operation_id(source_id),
         {:ok, match_value} <- normalize_match_value(match_value) do
      {:ok, %{kind: :delete, source_id: source_id, match_value: match_value}}
    end
  end

  defp normalize_operation(_operation),
    do: {:error, {:invalid_operation, %{code: :unsupported_shape}}}

  defp cast_operation_id(id) do
    case cast_uuid(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:invalid_operation, %{code: :invalid_label_setting_id, id: id}}}
    end
  end

  defp normalize_match_value(:any), do: {:ok, :any}
  defp normalize_match_value({:exact, value}), do: {:ok, {:exact, value}}

  defp normalize_match_value(_value),
    do: {:error, {:invalid_operation, %{code: :unsupported_shape}}}

  defp normalize_note_ids(note_ids), do: normalize_note_ids(note_ids, @max_active_selection)

  defp normalize_note_ids(note_ids, _limit) when not is_list(note_ids),
    do: {:error, {:invalid_selection, %{code: :must_be_a_list}}}

  defp normalize_note_ids([], _limit),
    do: {:error, {:invalid_selection, %{code: :empty}}}

  defp normalize_note_ids(note_ids, limit) when length(note_ids) > limit,
    do: {:error, {:invalid_selection, %{code: :too_many, limit: limit}}}

  defp normalize_note_ids(note_ids, _limit) do
    note_ids
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn original_id, {:ok, {ids, seen}} ->
      case cast_uuid(original_id) do
        :error ->
          {:halt, {:error, {:invalid_selection, %{code: :invalid_id, id: original_id}}}}

        {:ok, id} ->
          if MapSet.member?(seen, id) do
            {:halt, {:error, {:invalid_selection, %{code: :duplicate, id: id}}}}
          else
            {:cont, {:ok, {[id | ids], MapSet.put(seen, id)}}}
          end
      end
    end)
    |> case do
      {:ok, {ids, _seen}} -> {:ok, Enum.sort(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cast_uuid(id) do
    Ecto.UUID.cast(id)
  rescue
    _error -> :error
  end

  defp lock_label_settings(operation) do
    ids = referenced_setting_ids(operation)

    settings =
      LabelSetting
      |> where([setting], setting.id in ^ids)
      |> order_by([setting], asc: setting.id)
      |> lock("FOR SHARE")
      |> Repo.all()

    settings_by_id = Map.new(settings, &{&1.id, &1})
    missing_ids = Enum.reject(ids, &Map.has_key?(settings_by_id, &1))

    if missing_ids == [] do
      {:ok, settings_by_id}
    else
      {:error, {:label_settings_unavailable, %{ids: missing_ids}}}
    end
  end

  defp referenced_setting_ids(%{kind: :add, target_id: target_id}), do: [target_id]

  defp referenced_setting_ids(%{kind: :edit, source_id: source_id, target_id: target_id}),
    do: Enum.sort(Enum.uniq([source_id, target_id]))

  defp referenced_setting_ids(%{kind: :delete, source_id: source_id}), do: [source_id]

  defp validate_values(%{kind: :add} = operation, settings) do
    with {:ok, value} <- validate_value(settings, operation.target_id, operation.target_value) do
      {:ok, %{operation | target_value: value}}
    end
  end

  defp validate_values(%{kind: :edit} = operation, settings) do
    with {:ok, match_value} <-
           validate_match_value(settings, operation.source_id, operation.match_value),
         {:ok, target_value} <-
           validate_value(settings, operation.target_id, operation.target_value) do
      {:ok, %{operation | match_value: match_value, target_value: target_value}}
    end
  end

  defp validate_values(%{kind: :delete} = operation, settings) do
    with {:ok, match_value} <-
           validate_match_value(settings, operation.source_id, operation.match_value) do
      {:ok, %{operation | match_value: match_value}}
    end
  end

  defp validate_match_value(_settings, _setting_id, :any), do: {:ok, :any}

  defp validate_match_value(settings, setting_id, {:exact, value}) do
    with {:ok, value} <- validate_value(settings, setting_id, value) do
      {:ok, {:exact, value}}
    end
  end

  defp validate_value(settings, setting_id, value) do
    settings
    |> Map.fetch!(setting_id)
    |> LabelValue.validate(value)
  rescue
    Protocol.UndefinedError ->
      {:error, {:invalid_operation, %{code: :invalid_value}}}
  end

  defp lock_active_notes(note_ids) do
    notes =
      Note
      |> where([note], note.id in ^note_ids and is_nil(note.deleted_at))
      |> order_by([note], asc: note.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    found_ids = MapSet.new(notes, & &1.id)
    missing_ids = Enum.reject(note_ids, &MapSet.member?(found_ids, &1))

    if missing_ids == [] do
      {:ok, notes}
    else
      {:error, {:notes_unavailable, %{state: :active, ids: missing_ids}}}
    end
  end

  defp lock_deleted_notes(note_ids) do
    notes =
      Note
      |> where([note], note.id in ^note_ids and not is_nil(note.deleted_at))
      |> order_by([note], asc: note.id)
      |> lock("FOR UPDATE")
      |> Repo.all()

    found_ids = MapSet.new(notes, & &1.id)
    missing_ids = Enum.reject(note_ids, &MapSet.member?(found_ids, &1))

    if missing_ids == [] do
      {:ok, notes}
    else
      {:error, {:notes_unavailable, %{state: :deleted, ids: missing_ids}}}
    end
  end

  defp lock_labels(note_ids) do
    Label
    |> where([label], label.note_id in ^note_ids)
    |> order_by([label], asc: label.note_id, asc: label.label_setting_id)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp plan(%{kind: :add} = operation, notes, labels) do
    labels_by_note = labels_by_note(labels)

    conflicts =
      Enum.flat_map(notes, fn note ->
        case get_in(labels_by_note, [note.id, operation.target_id]) do
          %Label{value: value} ->
            if LabelValue.normalize(value) == operation.target_value, do: [], else: [note.id]

          nil ->
            []
        end
      end)

    if conflicts == [] do
      changes =
        Enum.flat_map(notes, fn note ->
          case get_in(labels_by_note, [note.id, operation.target_id]) do
            nil -> [{note, {:insert, note.id, operation.target_id, operation.target_value}}]
            %Label{} -> []
          end
        end)

      {:ok, %{matched: length(notes), changes: changes}}
    else
      {:error,
       {:label_conflict,
        %{
          operation: :add,
          label_setting_id: operation.target_id,
          note_ids: Enum.sort(conflicts)
        }}}
    end
  end

  defp plan(%{kind: :edit} = operation, notes, labels) do
    labels_by_note = labels_by_note(labels)

    matches =
      Enum.flat_map(notes, fn note ->
        case get_in(labels_by_note, [note.id, operation.source_id]) do
          %Label{} = label ->
            if label_matches?(label, operation.match_value), do: [{note, label}], else: []

          nil ->
            []
        end
      end)

    conflicts = edit_conflicts(matches, labels_by_note, operation)

    if conflicts == [] do
      changes =
        Enum.flat_map(matches, fn {note, label} ->
          cond do
            operation.source_id == operation.target_id and
                LabelValue.normalize(label.value) == operation.target_value ->
              []

            operation.source_id == operation.target_id ->
              [{note, {:update, label, operation.target_value}}]

            true ->
              [{note, {:move, label, operation.target_id, operation.target_value}}]
          end
        end)

      {:ok, %{matched: length(matches), changes: changes}}
    else
      {:error,
       {:label_conflict,
        %{
          operation: :edit,
          label_setting_id: operation.target_id,
          note_ids: Enum.sort(conflicts)
        }}}
    end
  end

  defp plan(%{kind: :delete} = operation, notes, labels) do
    labels_by_note = labels_by_note(labels)

    changes =
      Enum.flat_map(notes, fn note ->
        case get_in(labels_by_note, [note.id, operation.source_id]) do
          %Label{} = label ->
            if label_matches?(label, operation.match_value),
              do: [{note, {:delete, label}}],
              else: []

          nil ->
            []
        end
      end)

    {:ok, %{matched: length(changes), changes: changes}}
  end

  defp labels_by_note(labels) do
    Enum.reduce(labels, %{}, fn label, by_note ->
      Map.update(by_note, label.note_id, %{label.label_setting_id => label}, fn note_labels ->
        Map.put(note_labels, label.label_setting_id, label)
      end)
    end)
  end

  defp label_matches?(_label, :any), do: true

  defp label_matches?(label, {:exact, value}),
    do: LabelValue.normalize(label.value) == value

  defp edit_conflicts(_matches, _labels_by_note, %{source_id: id, target_id: id}), do: []

  defp edit_conflicts(matches, labels_by_note, operation) do
    Enum.flat_map(matches, fn {note, _label} ->
      if get_in(labels_by_note, [note.id, operation.target_id]), do: [note.id], else: []
    end)
  end

  defp apply_changes(changes) do
    Enum.reduce_while(changes, :ok, fn {_note, change}, :ok ->
      case apply_change(change) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_change({:insert, note_id, label_setting_id, value}) do
    insert_label(note_id, label_setting_id, value)
  end

  defp apply_change({:update, label, value}) do
    query =
      from(existing in Label,
        where:
          existing.note_id == ^label.note_id and
            existing.label_setting_id == ^label.label_setting_id
      )

    case Repo.update_all(query, set: [value: value, status: "valid", errors: []]) do
      {1, nil} -> :ok
      _result -> {:error, {:batch_write_failed, %{operation: :update, note_id: label.note_id}}}
    end
  end

  defp apply_change({:move, label, target_id, value}) do
    with :ok <- delete_label(label),
         :ok <- insert_label(label.note_id, target_id, value) do
      :ok
    end
  end

  defp apply_change({:delete, label}), do: delete_label(label)

  defp soft_delete_notes(notes, deleted_at) do
    Enum.reduce_while(notes, :ok, fn note, :ok ->
      case soft_delete_note(note, deleted_at) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp soft_delete_note(note, deleted_at) do
    note
    |> Ecto.Changeset.change(deleted_at: deleted_at)
    |> Repo.update()
    |> case do
      {:ok, _note} -> :ok
      {:error, reason} -> {:error, batch_write_error(:delete, note.id, reason)}
    end
  rescue
    exception in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      {:error, batch_write_error(:delete, note.id, exception)}
  end

  defp storage_file_ids(notes) do
    notes
    |> Enum.flat_map(& &1.attachments)
    |> Enum.map(& &1.storage_file_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp schedule_purges(storage_file_ids) do
    case Attachments.schedule_purges(storage_file_ids) do
      {:ok, _jobs} -> :ok
      {:error, reason} -> {:error, batch_purge_error(reason)}
    end
  rescue
    exception in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      {:error, batch_purge_error(exception)}
  end

  defp purge_notes(notes) do
    Enum.reduce_while(notes, :ok, fn note, :ok ->
      case purge_note(note) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp purge_note(note) do
    case Repo.delete(note) do
      {:ok, _note} -> :ok
      {:error, reason} -> {:error, batch_write_error(:purge, note.id, reason)}
    end
  rescue
    exception in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      {:error, batch_write_error(:purge, note.id, exception)}
  end

  defp insert_label(note_id, label_setting_id, value) do
    %Label{}
    |> Label.changeset(%{
      note_id: note_id,
      label_setting_id: label_setting_id,
      value: value,
      status: "valid",
      errors: []
    })
    |> Repo.insert()
    |> case do
      {:ok, _label} -> :ok
      {:error, reason} -> {:error, batch_write_error(:insert, note_id, reason)}
    end
  rescue
    exception in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      {:error, batch_write_error(:insert, note_id, exception)}
  end

  defp delete_label(label) do
    query =
      from(existing in Label,
        where:
          existing.note_id == ^label.note_id and
            existing.label_setting_id == ^label.label_setting_id
      )

    case Repo.delete_all(query) do
      {1, nil} -> :ok
      _result -> {:error, {:batch_write_failed, %{operation: :delete, note_id: label.note_id}}}
    end
  end

  defp audit_changes(changes, operation, actor) do
    Enum.reduce_while(changes, :ok, fn {note, _change}, :ok ->
      details = %{
        "title" => note.title,
        "fields" => ["labels"],
        "batch" => %{"operation" => Atom.to_string(operation)}
      }

      case insert_audit(note, actor, details) do
        {:ok, _log} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp audit_deleted_notes(notes, deleted_at, actor) do
    audit_notes(notes, "delete", actor, fn note ->
      %{
        "title" => note.title,
        "deleted_at" => deleted_at,
        "batch" => %{"operation" => "delete"}
      }
    end)
  end

  defp audit_purged_notes(notes, actor) do
    audit_notes(notes, "purge", actor, fn note ->
      %{
        "title" => note.title,
        "batch" => %{"operation" => "purge"}
      }
    end)
  end

  defp audit_notes(notes, action, actor, details) do
    Enum.reduce_while(notes, :ok, fn note, :ok ->
      case insert_audit(action, note, actor, details.(note)) do
        {:ok, _log} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp insert_audit(note, actor, details) do
    insert_audit("update", note, actor, details)
  end

  defp insert_audit(action, note, actor, details) do
    case Audit.log(action, "note", note.id, note.id, actor, details) do
      {:ok, _log} = result -> result
      {:error, reason} -> {:error, batch_audit_error(note.id, reason)}
    end
  rescue
    exception in [Ecto.ConstraintError, Ecto.StaleEntryError] ->
      {:error, batch_audit_error(note.id, exception)}
  end

  defp batch_write_error(operation, note_id, reason) do
    {:batch_write_failed,
     %{operation: operation, note_id: note_id, reason: safe_persistence_reason(reason)}}
  end

  defp batch_audit_error(note_id, reason) do
    {:batch_audit_failed, %{note_id: note_id, reason: safe_persistence_reason(reason)}}
  end

  defp batch_purge_error(reason) do
    {:batch_purge_failed, %{operation: :schedule_purges, reason: safe_persistence_reason(reason)}}
  end

  defp safe_persistence_reason(%Ecto.Changeset{} = changeset) do
    errors =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Enum.reduce(opts, message, fn {key, value}, rendered ->
          String.replace(rendered, "%{#{key}}", to_string(value))
        end)
      end)

    %{type: :changeset, errors: errors}
  end

  defp safe_persistence_reason(%Ecto.ConstraintError{} = error) do
    %{type: :constraint, constraint_type: error.type, constraint: error.constraint}
  end

  defp safe_persistence_reason(%Ecto.StaleEntryError{}), do: %{type: :stale}
  defp safe_persistence_reason(reason) when is_atom(reason), do: reason
  defp safe_persistence_reason(_reason), do: :persistence_error
end
