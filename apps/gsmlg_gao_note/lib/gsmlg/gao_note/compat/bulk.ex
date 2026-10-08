defmodule GSMLG.GaoNote.Compat.Bulk do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Audit, Note}
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.{Catalog, LabelSelector}
  alias GSMLG.Repo

  def selector(attrs, actor) do
    selector = Compat.field(attrs, :selector, "")

    with true <-
           is_binary(selector) and String.trim(selector) != "" and
             not Enum.any?(String.split(selector, "&"), &(String.trim(&1) == "")),
         {:ok, selectors} <- LabelSelector.parse(selector),
         :ok <- selector_keys(selectors),
         {:ok, set} <- Catalog.normalize(Compat.field(attrs, :set, [])),
         {:ok, remove} <- remove_keys(Compat.field(attrs, :remove, [])),
         :ok <- validate_mutations(set, remove),
         :ok <- Catalog.validate_values(set) do
      Repo.transaction(fn ->
        notes =
          Note
          |> where([n], is_nil(n.deleted_at))
          |> order_by([n], asc: n.id)
          |> lock("FOR UPDATE")
          |> Repo.all()
          |> Repo.preload(labels: :label_setting)

        notes = Enum.filter(notes, &LabelSelector.matches_all?(label_maps(&1), selectors))

        updated =
          Enum.count(notes, fn note ->
            desired =
              note
              |> Catalog.pairs()
              |> Map.new()
              |> Map.drop(remove)
              |> Map.merge(Map.new(set))
              |> Enum.sort()

            change_labels(note, desired, actor)
          end)

        %{matched: length(notes), updated: updated, unchanged: length(notes) - updated}
      end)
    else
      false -> Compat.invalid("selector must not be empty or malformed")
      {:error, {:invalid_input, _}} = error -> error
      {:error, {:validation_error, _}} = error -> error
      {:error, message} -> Compat.invalid(message)
    end
  end

  def labels(attrs, actor) do
    action = Compat.field(attrs, :action)

    with {:ok, targets} <- targets(Compat.field(attrs, :notes)),
         {:ok, action} <- normalize_action(action),
         :ok <- validate_action(action) do
      Repo.transaction(fn ->
        notes = preflight(targets, :active)

        updated =
          Enum.count(notes, fn note ->
            labels = Map.new(Catalog.pairs(note))

            desired =
              case action do
                {:add, key, value} ->
                  Map.put_new(labels, key, value)

                {:remove, key} ->
                  Map.delete(labels, key)

                {:update, from, key, value} ->
                  if Map.has_key?(labels, from),
                    do: labels |> Map.delete(from) |> Map.put(key, value),
                    else: labels
              end

            change_labels(note, Enum.sort(desired), actor)
          end)

        %{requested: length(notes), updated: updated, unchanged: length(notes) - updated}
      end)
    end
  end

  def lifecycle(attrs, actor, operation) do
    raw = if is_list(attrs), do: attrs, else: Compat.field(attrs, :notes)

    with {:ok, targets} <- targets(raw) do
      Repo.transaction(fn ->
        state = if operation == :delete, do: :active, else: :deleted
        notes = preflight(targets, state)

        Enum.each(notes, fn note ->
          result =
            case operation do
              :delete -> GaoNote.delete_note(note, actor)
              :restore -> GaoNote.restore_note(note, actor)
              :purge -> GaoNote.permanently_delete_note(note, actor)
            end

          case result do
            {:ok, _} -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

        key =
          case operation do
            :delete -> :deleted
            :restore -> :restored
            :purge -> :deleted
          end

        %{key => length(notes), :requested => length(notes)}
      end)
    end
  end

  defp targets(raw) when is_list(raw) and length(raw) > 0 and length(raw) <= 1000 do
    Enum.reduce_while(raw, {:ok, []}, fn target, {:ok, acc} ->
      target = if is_map(target), do: target, else: %{}
      id = Compat.field(target, :id)
      revision = Compat.field(target, :expected_revision)

      with {:ok, id} <- Ecto.UUID.cast(id), :ok <- Compat.positive_revision(revision) do
        if Enum.any?(acc, &(&1.id == id)),
          do: {:halt, Compat.invalid("duplicate note target id")},
          else: {:cont, {:ok, [%{id: id, revision: revision} | acc]}}
      else
        _ -> {:halt, Compat.invalid("invalid note target")}
      end
    end)
    |> case do
      {:ok, targets} -> {:ok, Enum.sort_by(targets, & &1.id)}
      error -> error
    end
  end

  defp targets(_), do: Compat.invalid("note targets must contain between 1 and 1000 entries")

  defp preflight(targets, state) do
    Enum.map(targets, fn target ->
      with {:ok, note} <- Compat.lock_note(target.id, state),
           :ok <- Compat.ensure_revision(note, target.revision) do
        note
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp change_labels(note, desired, actor) do
    if Catalog.pairs(note) == desired do
      false
    else
      with :ok <- Catalog.replace(note, desired),
           {:ok, _} <- GaoNote.advance_revision(note),
           {:ok, _} <-
             Audit.log("update", "note", note.id, note.id, actor, %{"fields" => ["labels"]}) do
        true
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  defp selector_keys(selectors) do
    Enum.reduce_while(selectors, :ok, fn selector, :ok ->
      case Catalog.validate_key(selector.key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_action({:remove, _}), do: :ok
  defp validate_action({:add, key, value}), do: Catalog.validate_values([{key, value}])
  defp validate_action({:update, _, key, value}), do: Catalog.validate_values([{key, value}])

  defp normalize_action(action) when is_map(action) do
    type = Compat.field(action, :type)
    key = Compat.field(action, :key)
    value = Compat.field(action, :value, "")
    from = Compat.field(action, :from_key)

    with :ok <- Catalog.validate_key(key) do
      case type do
        "add" when is_binary(value) ->
          {:ok, {:add, key, value}}

        "remove" ->
          {:ok, {:remove, key}}

        "update" when is_binary(value) ->
          with :ok <- Catalog.validate_key(from), do: {:ok, {:update, from, key, value}}

        _ ->
          Compat.invalid("unsupported batch label action")
      end
    end
  end

  defp normalize_action(_), do: Compat.invalid("batch label action must be an object")

  defp remove_keys(keys) when is_list(keys) do
    Enum.reduce_while(keys, {:ok, []}, fn key, {:ok, acc} ->
      case Catalog.validate_key(key) do
        :ok ->
          if key in acc,
            do: {:halt, Compat.invalid("duplicate label removal key")},
            else: {:cont, {:ok, [key | acc]}}

        error ->
          {:halt, error}
      end
    end)
  end

  defp remove_keys(_), do: Compat.invalid("remove must be an array")
  defp validate_mutations([], []), do: Compat.invalid("at least one label mutation is required")

  defp validate_mutations(set, remove) do
    if Enum.any?(set, fn {key, _} -> key in remove end),
      do: Compat.invalid("label cannot be both set and removed"),
      else: :ok
  end

  defp label_maps(note),
    do:
      Enum.map(note.labels, fn label ->
        %{
          key: label.label_setting.name,
          value: label.value || "",
          value_type: label.label_setting.value_type
        }
      end)
end
