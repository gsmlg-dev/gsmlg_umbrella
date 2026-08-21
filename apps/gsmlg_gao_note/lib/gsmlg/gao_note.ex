defmodule GSMLG.GaoNote do
  @moduledoc """
  Domain context for GaoNote notes, label settings, and storage-backed attachments.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi

  alias GSMLG.GaoNote.{
    Attachments,
    Audit,
    CategorySetting,
    Label,
    LabelSetting,
    LabelValue,
    Log,
    MCPSetting,
    Note
  }

  alias GSMLG.Repo

  @default_limit 50
  @max_limit 200
  @labels_not_provided :__gao_note_labels_not_provided__
  @mcp_setting_id "default"
  @category_label_in_use_message "Remove every category using this label from Category labels before deleting it."
  @note_attr_keys %{
    "title" => :title,
    :title => :title,
    "content" => :content,
    :content => :content,
    "labels" => :labels,
    :labels => :labels,
    "attachments" => :attachments,
    :attachments => :attachments
  }
  @note_field_attr_keys %{
    "title" => :title,
    :title => :title,
    "content" => :content,
    :content => :content,
    "labels" => :labels,
    :labels => :labels
  }
  @label_setting_attr_keys %{
    "name" => :name,
    :name => :name,
    "color" => :color,
    :color => :color,
    "description" => :description,
    :description => :description,
    "value_type" => :value_type,
    :value_type => :value_type,
    "metadata" => :metadata,
    :metadata => :metadata
  }
  @option_keys %{
    "search" => :search,
    :search => :search,
    "label" => :label,
    :label => :label,
    "order_by" => :order_by,
    :order_by => :order_by,
    "limit" => :limit,
    :limit => :limit,
    "offset" => :offset,
    :offset => :offset,
    "action" => :action,
    :action => :action,
    "entity_type" => :entity_type,
    :entity_type => :entity_type,
    "note_id" => :note_id,
    :note_id => :note_id
  }

  def public_note_query, do: active_note_query()

  def list_notes(opts \\ []) do
    list_notes_from(active_note_query(), opts)
  end

  def list_public_notes(opts \\ []) do
    list_notes_from(public_note_query(), opts)
  end

  def search_notes(query, opts \\ []) do
    opts
    |> Keyword.put(:search, query)
    |> list_notes()
  end

  def search_public_notes(query, opts \\ []) do
    opts
    |> Keyword.put(:search, query)
    |> list_public_notes()
  end

  def get_note(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      active_note_query()
      |> preload([labels: :label_setting, attachments: :storage_file])
      |> Repo.get(id)
    else
      :error -> nil
    end
  end

  def get_note!(id) do
    active_note_query()
    |> preload([labels: :label_setting, attachments: :storage_file])
    |> Repo.get!(id)
  end

  def get_public_note(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      public_note_query()
      |> where([n], n.id == ^id)
      |> preload([labels: :label_setting, attachments: :storage_file])
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def list_deleted_notes(opts \\ []) do
    opts = normalize_opts(opts)

    deleted_note_query()
    |> filter_by_search(opts[:search])
    |> filter_by_label(opts[:label])
    |> order_by([n], desc: n.deleted_at, desc: n.updated_at)
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload([labels: :label_setting, attachments: :storage_file])
    |> Repo.all()
  end

  def get_deleted_note(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      deleted_note_query()
      |> preload([labels: :label_setting, attachments: :storage_file])
      |> Repo.get(id)
    else
      :error -> nil
    end
  end

  def list_label_settings(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    active_note_counts =
      Label
      |> join(:inner, [label], note in Note,
        on: note.id == label.note_id and is_nil(note.deleted_at)
      )
      |> group_by([label], label.label_setting_id)
      |> select([label, note], %{
        label_setting_id: label.label_setting_id,
        note_count: count(note.id)
      })

    category_counts =
      CategorySetting
      |> group_by([category], category.label_setting_id)
      |> select([category], %{
        label_setting_id: category.label_setting_id,
        category_count: count(category.id)
      })

    LabelSetting
    |> join(:left, [label_setting], note_count in subquery(active_note_counts),
      on: note_count.label_setting_id == label_setting.id
    )
    |> join(:left, [label_setting], category_count in subquery(category_counts),
      on: category_count.label_setting_id == label_setting.id
    )
    |> select_merge([_label_setting, note_count, category_count], %{
      note_count: coalesce(note_count.note_count, 0),
      category_count: coalesce(category_count.category_count, 0)
    })
    |> order_by([t], asc: fragment("lower(?)", t.name))
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def save_category_settings(selectors) when is_list(selectors) do
    with {:ok, normalized_selectors} <- normalize_category_selectors(selectors) do
      Repo.transaction(fn ->
        lock_category_settings()
        Repo.delete_all(CategorySetting)

        normalized_selectors
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {selector, position}, :ok ->
          result =
            %CategorySetting{}
            |> CategorySetting.changeset(Map.put(selector, :position, position))
            |> Repo.insert()

          case result do
            {:ok, _category} -> {:cont, :ok}
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

        list_category_settings()
      end)
    end
  end

  def save_category_settings(_selectors), do: {:error, :category_settings_must_be_a_list}

  def list_category_groups do
    configured_label_setting_ids =
      CategorySetting
      |> distinct(true)
      |> select([category], %{label_setting_id: category.label_setting_id})

    active_counts =
      Label
      |> join(:inner, [label], configured in subquery(configured_label_setting_ids),
        on: configured.label_setting_id == label.label_setting_id
      )
      |> join(:inner, [label, _configured], note in Note, on: note.id == label.note_id)
      |> where(
        [label, _configured, note],
        is_nil(note.deleted_at) and not is_nil(label.value) and label.value != ""
      )
      |> group_by([label], [label.label_setting_id, label.value])
      |> select([label, _configured, note], %{
        label_setting_id: label.label_setting_id,
        value: label.value,
        count: count(note.id)
      })

    CategorySetting
    |> join(:inner, [category], label_setting in assoc(category, :label_setting))
    |> join(:left, [category], count_row in subquery(active_counts),
      on:
        count_row.label_setting_id == category.label_setting_id and
          (is_nil(category.value) or count_row.value == category.value)
    )
    |> order_by([category], asc: category.position)
    |> select([category, label_setting, count_row], %{
      category: category,
      label_setting: label_setting,
      value: count_row.value,
      count: count_row.count
    })
    |> Repo.all()
    |> Enum.chunk_by(& &1.category.id)
    |> Enum.map(&category_group/1)
  end

  def get_label_setting(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(LabelSetting, id)
    else
      :error -> nil
    end
  end

  def get_label_setting!(id), do: Repo.get!(LabelSetting, id)

  def get_attachment_by_path(note_id, path), do: Attachments.get_by_path(note_id, path)

  def get_deleted_attachment_by_path(note_id, path),
    do: Attachments.get_deleted_by_path(note_id, path)

  def read_attachment_text(note_id, attachment_id),
    do: Attachments.read_text(note_id, attachment_id)

  def get_attachment_with_content(note_id, attachment_id),
    do: Attachments.get_with_content(note_id, attachment_id)

  def put_attachment(note_id, attachment_id, attrs, actor) do
    Attachments.put(note_id, attachment_id, attrs, actor_id(actor))
    |> tap_success(fn attachment ->
      log_action(
        "update",
        "attachment",
        attachment.id,
        attachment.note_id,
        actor,
        %{
          "path" => attachment.path,
          "mime" => attachment.mime,
          "description" => attachment.description,
          "storage_file_id" => attachment.storage_file_id,
          "content_updated" => attachment_update_content(attrs)
        }
      )
    end)
  end

  def delete_attachment(note_id, attachment_id, actor) do
    Attachments.delete(note_id, attachment_id)
    |> tap_success(fn attachment ->
      log_action(
        "delete",
        "attachment",
        attachment.id,
        attachment.note_id,
        actor,
        %{
          "path" => attachment.path,
          "mime" => attachment.mime,
          "description" => attachment.description,
          "storage_file_id" => attachment.storage_file_id
        }
      )
    end)
  end

  def list_logs(opts \\ []) do
    opts = normalize_opts(opts)

    Log
    |> filter_log_action(opts[:action])
    |> filter_log_entity(opts[:entity_type])
    |> filter_log_note(opts[:note_id])
    |> order_by([l], desc: l.created_at)
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> Repo.all()
  end

  def get_mcp_setting do
    Repo.get(MCPSetting, @mcp_setting_id)
  end

  def generate_mcp_api_key do
    "gnmcp_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  def set_mcp_api_key(api_key, actor) when is_binary(api_key) do
    api_key = String.trim(api_key)

    cond do
      blank?(api_key) ->
        {:error, :api_key_required}

      blank?(actor_id(actor)) ->
        {:error, :actor_required}

      true ->
        setting = get_mcp_setting() || %MCPSetting{}

        setting
        |> MCPSetting.changeset(%{
          id: @mcp_setting_id,
          api_key_hash: hash_api_key(api_key),
          api_key_hint: api_key_hint(api_key),
          actor_id: actor_id(actor)
        })
        |> Repo.insert_or_update()
    end
  end

  def set_mcp_api_key(_api_key, _actor), do: {:error, :api_key_required}

  def verify_mcp_api_key(api_key) when is_binary(api_key) do
    api_key = String.trim(api_key)

    with false <- blank?(api_key),
         %MCPSetting{} = setting <- get_mcp_setting(),
         true <- secure_equal?(setting.api_key_hash, hash_api_key(api_key)),
         false <- blank?(setting.actor_id) do
      {:ok, %{id: setting.actor_id, source: "mcp_api_key"}}
    else
      _ -> :error
    end
  end

  def verify_mcp_api_key(_api_key), do: :error

  def change_note(%Note{} = note, attrs \\ %{}) do
    Note.changeset(note, normalize_attrs(attrs, @note_attr_keys))
  end

  def change_label_setting(%LabelSetting{} = label_setting, attrs \\ %{}) do
    LabelSetting.changeset(label_setting, normalize_attrs(attrs, @label_setting_attr_keys))
  end

  def create_label_setting(attrs, actor \\ nil) do
    %LabelSetting{}
    |> LabelSetting.changeset(normalize_attrs(attrs, @label_setting_attr_keys))
    |> Repo.insert()
    |> tap_success(fn label_setting ->
      log_action("create", "label_setting", label_setting.id, nil, actor, %{"name" => label_setting.name})
    end)
  end

  def update_label_setting(%LabelSetting{} = label_setting, attrs, actor \\ nil) do
    old_value_type = label_setting.value_type || "text"

    label_setting
    |> LabelSetting.changeset(normalize_attrs(attrs, @label_setting_attr_keys))
    |> Repo.update()
    |> tap_success(fn label_setting ->
      log_action("update", "label_setting", label_setting.id, nil, actor, %{
        "name" => label_setting.name,
        "fields" => changed_fields(attrs, @label_setting_attr_keys)
      })

      if old_value_type != (label_setting.value_type || "text") do
        async_revalidate_labels(label_setting)
      end
    end)
  end

  def delete_label_setting(%LabelSetting{} = label_setting, actor \\ nil) do
    if category_label_in_use?(label_setting.id) do
      category_label_in_use_error(label_setting)
    else
      label_setting
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.no_assoc_constraint(:category_settings,
        name: :gao_note_category_settings_label_setting_id_fkey,
        message: "remove every category using this label before deleting it"
      )
      |> Repo.delete()
      |> normalize_category_delete_result(label_setting)
      |> tap_success(fn label_setting ->
        log_action("delete", "label_setting", label_setting.id, nil, actor, %{
          "name" => label_setting.name
        })
      end)
    end
  end

  def create_note(attrs, actor) do
    attrs = normalize_attrs(attrs, @note_attr_keys)
    {label_source, label_values, attrs} = pop_labels_input(attrs)
    {attachment_values, attrs} = Map.pop(attrs, :attachments, [])
    note_id = Ecto.UUID.generate()

    with {:ok, labels} <- normalize_labels(label_values, label_source),
         {:ok, attachment_plan} <-
           Attachments.prepare(note_id, attachment_values, actor_id(actor)) do
      labels = if labels == @labels_not_provided, do: [], else: labels

      transaction_result =
        Attachments.transact(attachment_plan, fn ->
          with {:ok, note} <-
                 %Note{id: note_id}
                 |> Note.create_changeset(attrs)
                 |> Repo.insert(),
               {:ok, _note} <- set_labels_in_repo(note, labels),
               {:ok, _attachments} <- Attachments.reconcile(note.id, attachment_plan) do
            note
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case transaction_result do
        {:ok, note} ->
          note = preload_note(note)
          log_action("create", "note", note.id, note.id, actor, %{"title" => note.title})
          {:ok, note}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def update_note(%Note{} = note, attrs, actor) do
    attrs =
      attrs
      |> normalize_attrs(@note_attr_keys)

    with {:ok, attachment_values, attrs} <- pop_required_attachments(attrs) do
      {label_source, label_values, attrs} = pop_labels_input(attrs)

      with {:ok, labels} <- normalize_labels(label_values, label_source),
           {:ok, attachment_plan} <-
             Attachments.prepare(note.id, attachment_values, actor_id(actor)) do
        transaction_result =
          Attachments.transact(attachment_plan, fn ->
            with {:ok, locked_note} <- lock_active_note(note.id),
                 {:ok, updated_note} <-
                   locked_note
                   |> Note.changeset(attrs)
                   |> Repo.update(),
                 {:ok, _note} <- replace_labels_in_repo(updated_note, labels),
                 {:ok, _attachments} <-
                   Attachments.reconcile(updated_note.id, attachment_plan) do
              updated_note
            else
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case transaction_result do
          {:ok, note} ->
          note = preload_note(note)

          log_action("update", "note", note.id, note.id, actor, %{
            "title" => note.title,
            "fields" =>
              attrs
              |> changed_fields(@note_attr_keys, labels)
              |> Kernel.++(["attachments"])
              |> Enum.uniq()
          })

          {:ok, note}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def update_note_fields(%Note{} = note, attrs, actor) do
    with :ok <- reject_attachment_input(attrs) do
      attrs = normalize_attrs(attrs, @note_field_attr_keys)
      {label_source, label_values, attrs} = pop_labels_input(attrs)

      with {:ok, labels} <- normalize_labels(label_values, label_source) do
        note.id
        |> update_note_fields_in_repo(attrs, labels)
        |> case do
          {:ok, {updated, fields}} ->
            if fields != [] do
              log_action("update", "note", updated.id, updated.id, actor, %{
                "title" => updated.title,
                "fields" => fields
              })
            end

            {:ok, updated}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def delete_note(%Note{} = note, actor) do
    note
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
    |> Repo.update()
    |> tap_success(fn deleted ->
      log_action("delete", "note", deleted.id, deleted.id, actor, %{
        "title" => deleted.title,
        "deleted_at" => deleted.deleted_at
      })
    end)
  end

  def restore_note(%Note{} = note, actor) do
    transact_deleted_note(note.id, fn locked_note ->
      with {:ok, restored} <-
             locked_note
             |> Ecto.Changeset.change(deleted_at: nil)
             |> Repo.update(),
           {:ok, _log} <-
             log_action("restore", "note", restored.id, restored.id, actor, %{
               "title" => restored.title
             }) do
        {:ok, restored}
      end
    end)
  end

  def permanently_delete_note(%Note{} = note, actor) do
    transact_deleted_note(note.id, fn locked_note ->
      storage_file_ids =
        Enum.map(locked_note.attachments, & &1.storage_file_id)

      with {:ok, _jobs} <- Attachments.schedule_purges(storage_file_ids),
           {:ok, deleted} <- Repo.delete(locked_note),
           {:ok, _log} <-
             log_action("purge", "note", deleted.id, deleted.id, actor, %{
               "title" => deleted.title
             }) do
        {:ok, deleted}
      end
    end)
  end

  def set_labels(%Note{} = note, label_values, actor) do
    Multi.new()
    |> Multi.run(:labels, fn _repo, _changes ->
      with {:ok, labels} <- normalize_labels(label_values, :labels) do
        set_labels_in_repo(note, labels)
      end
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{labels: note}} ->
        note = preload_note(note)

        log_action("update", "note", note.id, note.id, actor, %{
          "title" => note.title,
          "fields" => ["labels"]
        })

        {:ok, note}

      {:error, :labels, reason, _changes} ->
        {:error, reason}
    end
  end

  defp list_category_settings do
    CategorySetting
    |> order_by([category], asc: category.position)
    |> preload(:label_setting)
    |> Repo.all()
  end

  defp lock_category_settings do
    Ecto.Adapters.SQL.query!(
      Repo,
      "LOCK TABLE gao_note_category_settings IN SHARE ROW EXCLUSIVE MODE",
      []
    )

    :ok
  end

  defp normalize_category_selectors(selectors) do
    with {:ok, normalized_selectors} <- normalize_category_selector_shapes(selectors) do
      label_settings_by_id =
        normalized_selectors
        |> Enum.map(& &1.label_setting_id)
        |> Enum.uniq()
        |> then(fn ids -> Repo.all(from(setting in LabelSetting, where: setting.id in ^ids)) end)
        |> Map.new(&{&1.id, &1})

      validate_category_selectors(normalized_selectors, label_settings_by_id)
    end
  end

  defp normalize_category_selector_shapes(selectors) do
    selectors
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {selector, index}, {:ok, normalized} ->
      case normalize_category_selector(selector, index) do
        {:ok, selector} -> {:cont, {:ok, [selector | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_category_selector(selector, index) when is_map(selector) do
    with {:ok, label_setting_id} <- category_selector_id(selector, index),
         {:ok, value} <- category_selector_value(selector, index) do
      {:ok, %{label_setting_id: label_setting_id, value: value}}
    end
  end

  defp normalize_category_selector(_selector, index),
    do: {:error, {:invalid_category_selector, index, :must_be_a_map}}

  defp category_selector_id(selector, index) do
    case fetch_category_selector_field(selector, :label_setting_id, "label_setting_id") do
      {:ok, label_setting_id} ->
        case Ecto.UUID.cast(label_setting_id) do
          {:ok, label_setting_id} -> {:ok, label_setting_id}
          :error -> {:error, {:invalid_category_selector, index, :invalid_label_setting_id}}
        end

      :error ->
        {:error, {:invalid_category_selector, index, :invalid_label_setting_id}}
    end
  end

  defp category_selector_value(selector, index) do
    case fetch_category_selector_field(selector, :value, "value") do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        value = String.trim(value)
        {:ok, if(value == "", do: nil, else: value)}

      {:ok, _value} ->
        {:error, {:invalid_category_selector, index, :invalid_value}}
    end
  end

  defp fetch_category_selector_field(selector, atom_key, string_key) do
    case Map.fetch(selector, atom_key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(selector, string_key)
    end
  end

  defp validate_category_selectors(normalized_selectors, label_settings_by_id) do
    normalized_selectors
    |> Enum.reduce_while({:ok, {[], MapSet.new()}}, fn selector, {:ok, {validated, seen}} ->
      case validate_category_selector(selector, label_settings_by_id, seen) do
        {:ok, seen} -> {:cont, {:ok, {[selector | validated], seen}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, {validated, _seen}} -> {:ok, Enum.reverse(validated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_category_selector(selector, label_settings_by_id, seen) do
    case Map.fetch(label_settings_by_id, selector.label_setting_id) do
      :error ->
        {:error, {:unknown_category_label, selector.label_setting_id}}

      {:ok, label_setting} ->
        with :ok <- validate_category_value(label_setting, selector.value),
             {:ok, seen} <- ensure_unique_category_selector(selector, seen) do
          {:ok, seen}
        end
    end
  end

  defp validate_category_value(_label_setting, nil), do: :ok

  defp validate_category_value(label_setting, value) do
    case LabelValue.classify(label_setting, value) do
      {"valid", []} -> :ok
      {"invalid", errors} -> {:error, {:invalid_category_value, label_setting.id, errors}}
    end
  end

  defp ensure_unique_category_selector(selector, seen) do
    selector_key = {selector.label_setting_id, selector.value}

    if MapSet.member?(seen, selector_key) do
      {:error, {:duplicate_category_selector, selector.label_setting_id, selector.value}}
    else
      {:ok, MapSet.put(seen, selector_key)}
    end
  end

  defp category_group([first | _rest] = rows) do
    key = LabelSetting.normalized_key(first.label_setting.name)

    values =
      rows
      |> Enum.flat_map(fn
        %{value: value, count: count} when is_binary(value) and is_integer(count) ->
          [%{value: value, count: count}]

        _row ->
          []
      end)
      |> Enum.sort_by(&{-&1.count, &1.value})

    %{
      id: first.category.id,
      label_setting_id: first.category.label_setting_id,
      key: key,
      selector: category_selector_name(key, first.category.value),
      configured_value: first.category.value,
      description: first.label_setting.description,
      position: first.category.position,
      values: values
    }
  end

  defp category_selector_name(key, nil), do: key
  defp category_selector_name(key, value), do: "#{key}=#{value}"

  defp category_label_in_use?(label_setting_id) do
    Repo.exists?(
      from(category in CategorySetting, where: category.label_setting_id == ^label_setting_id)
    )
  end

  defp normalize_category_delete_result(
         {:error, %Ecto.Changeset{} = changeset},
         %LabelSetting{} = label_setting
       ) do
    if Keyword.has_key?(changeset.errors, :category_settings) do
      category_label_in_use_error(label_setting)
    else
      {:error, changeset}
    end
  end

  defp normalize_category_delete_result(result, _label_setting), do: result

  defp category_label_in_use_error(%LabelSetting{} = label_setting) do
    {:error,
     {:category_label_in_use,
      %{
        label_setting_id: label_setting.id,
        name: label_setting.name,
        message: @category_label_in_use_message
      }}}
  end

  defp list_notes_from(queryable, opts) do
    opts = normalize_opts(opts)

    queryable
    |> filter_by_search(opts[:search])
    |> filter_by_label(opts[:label])
    |> apply_order(opts[:order_by])
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload([labels: :label_setting, attachments: :storage_file])
    |> Repo.all()
  end

  defp filter_by_search(query, nil), do: query
  defp filter_by_search(query, ""), do: query

  defp filter_by_search(query, search) when is_binary(search) do
    pattern = "%#{String.trim(search)}%"

    where(
      query,
      [n],
      ilike(n.title, ^pattern) or ilike(n.content, ^pattern)
    )
  end

  defp filter_by_label(query, nil), do: query
  defp filter_by_label(query, ""), do: query

  defp filter_by_label(query, label_filters) when is_list(label_filters) do
    Enum.reduce(label_filters, query, fn label_filter, filtered_query ->
      filter_by_label(filtered_query, label_filter)
    end)
  end

  defp filter_by_label(query, label_filter) when is_binary(label_filter) do
    case normalize_label_filter(label_filter) do
      {:ok, label_key, value} ->
        matching_note_ids =
          from(label in GSMLG.GaoNote.Label,
            join: setting in assoc(label, :label_setting),
            where: fragment("lower(?)", setting.name) == ^label_key,
            select: label.note_id
          )

        matching_note_ids =
          if is_nil(value) do
            matching_note_ids
          else
            where(matching_note_ids, [label, _setting], label.value == ^value)
          end

        where(query, [note], note.id in subquery(matching_note_ids))

      :error ->
        query
    end
  end

  defp normalize_label_filter(label_setting) when is_binary(label_setting) do
    case String.split(label_setting, "=", parts: 2) do
      [key, value] ->
        key = LabelSetting.normalized_key(key)
        if blank?(key), do: :error, else: {:ok, key, value_to_string(value)}

      [key] ->
        key = LabelSetting.normalized_key(key)
        if blank?(key), do: :error, else: {:ok, key, nil}
    end
  end

  defp normalize_label_filter(_label), do: :error

  defp filter_log_action(query, nil), do: query
  defp filter_log_action(query, ""), do: query
  defp filter_log_action(query, action), do: where(query, [l], l.action == ^action)

  defp filter_log_entity(query, nil), do: query
  defp filter_log_entity(query, ""), do: query
  defp filter_log_entity(query, entity_type), do: where(query, [l], l.entity_type == ^entity_type)

  defp filter_log_note(query, nil), do: query
  defp filter_log_note(query, ""), do: query

  defp filter_log_note(query, note_id) do
    with {:ok, note_id} <- Ecto.UUID.cast(note_id) do
      where(query, [l], l.note_id == ^note_id)
    else
      :error -> where(query, [_l], false)
    end
  end

  defp apply_order(query, nil) do
    order_by(query, [n], desc: n.updated_at)
  end

  defp apply_order(query, :updated_at), do: order_by(query, [n], desc: n.updated_at)
  defp apply_order(query, _other), do: apply_order(query, nil)

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, limit), do: limit(query, ^limit_value(limit))

  defp limit_value(nil), do: @default_limit
  defp limit_value(value) when is_integer(value), do: min(max(value, 1), @max_limit)

  defp limit_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> limit_value(parsed)
      _ -> @default_limit
    end
  end

  defp limit_value(_value), do: @default_limit

  defp offset_value(nil), do: 0
  defp offset_value(value) when is_integer(value), do: max(value, 0)

  defp offset_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> offset_value(parsed)
      _ -> 0
    end
  end

  defp offset_value(_value), do: 0

  defp replace_labels_in_repo(%Note{} = note, @labels_not_provided), do: {:ok, note}
  defp replace_labels_in_repo(%Note{} = note, labels), do: set_labels_in_repo(note, labels)

  defp set_labels_in_repo(%Note{} = note, labels) when is_list(labels) do
    label_keys = Enum.map(labels, & &1.name)

    with {:ok, label_settings} <- get_or_insert_label_settings(label_keys) do
      label_setting_by_key =
        label_settings
        |> Enum.map(&{LabelSetting.normalized_key(&1.name), &1})
        |> Map.new()

      Repo.delete_all(from(t in Label, where: t.note_id == ^note.id))

      Enum.reduce_while(labels, {:ok, []}, fn label, {:ok, labels} ->
        label_setting = Map.fetch!(label_setting_by_key, label.normalized_key)
        {status, errors} = LabelValue.classify(label_setting, label.value)

        attrs = %{
          note_id: note.id,
          label_setting_id: label_setting.id,
          value: value_to_string(label.value),
          status: status,
          errors: errors
        }

        case %Label{} |> Label.changeset(attrs) |> Repo.insert() do
          {:ok, label} -> {:cont, {:ok, [label | labels]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, _labels} -> {:ok, preload_note(note)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp pop_labels_input(attrs) when is_map(attrs) do
    {labels, attrs} = Map.pop(attrs, :labels, @labels_not_provided)

    cond do
      labels != @labels_not_provided -> {:labels, labels, attrs}
      true -> {@labels_not_provided, @labels_not_provided, attrs}
    end
  end

  defp pop_required_attachments(attrs) do
    case Map.fetch(attrs, :attachments) do
      {:ok, attachments} when is_list(attachments) ->
        {:ok, attachments, Map.delete(attrs, :attachments)}

      {:ok, _attachments} ->
        {:error, {:attachments, %{code: :must_be_a_list}}}

      :error ->
        {:error, {:attachments, %{code: :required}}}
    end
  end

  defp normalize_labels(@labels_not_provided, @labels_not_provided),
    do: {:ok, @labels_not_provided}

  defp normalize_labels(nil, _source), do: {:ok, []}

  defp normalize_labels(labels, source) when is_list(labels) do
    labels
    |> Enum.reduce_while({:ok, []}, fn label, {:ok, labels} ->
      case normalize_label(label, source) do
        {:ok, nil} -> {:cont, {:ok, labels}}
        {:ok, label} -> {:cont, {:ok, [label | labels]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, labels} ->
        labels =
          labels
          |> Enum.reverse()
          |> Enum.uniq_by(& &1.normalized_key)
          |> Enum.sort_by(& &1.normalized_key)

        {:ok, labels}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_labels(_labels, :labels), do: {:error, "labels must be an array"}
  defp normalize_label(label, :labels) when is_binary(label) do
    case String.split(label, "=", parts: 2) do
      [key, value] -> normalize_label_pair(key, value)
      [key] -> normalize_label_pair(key, "")
    end
  end

  defp normalize_label(%{} = label, :labels) do
    key =
      Map.get(label, :key) ||
        Map.get(label, "key") ||
        Map.get(label, :name) ||
        Map.get(label, "name")

    value = Map.get(label, :value, Map.get(label, "value", ""))
    normalize_label_pair(key, value)
  end

  defp normalize_label(_label, :labels),
    do: {:error, "labels must be strings like key=value or maps with key/value"}

  defp normalize_label_pair(key, value) do
    key = normalize_label_key(key)

    if blank?(key) do
      {:ok, nil}
    else
      {:ok,
       %{
         name: key,
         normalized_key: LabelSetting.normalized_key(key),
         value: value_to_string(value)
       }}
    end
  end

  defp normalize_label_key(key) when is_binary(key), do: LabelSetting.normalize_display_name(key)

  defp normalize_label_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> normalize_label_key()

  defp normalize_label_key(_key), do: ""

  defp get_or_insert_label_settings(label_names) do
    label_names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, label_settings} ->
      case get_or_insert_label_setting(name) do
        {:ok, label_setting} -> {:cont, {:ok, [label_setting | label_settings]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, label_settings} -> {:ok, Enum.sort_by(label_settings, &LabelSetting.normalized_key(&1.name))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_or_insert_label_setting(name) do
    label_key = LabelSetting.normalized_key(name)

    case label_setting_by_normalized_name(label_key) do
      %LabelSetting{} = label_setting ->
        {:ok, label_setting}

      nil ->
        insert_label_setting(name)
    end
  end

  defp label_setting_by_normalized_name(label_key) do
    LabelSetting
    |> where([setting], fragment("lower(?)", setting.name) == ^label_key)
    |> Repo.one()
  end

  defp insert_label_setting(name) do
    now = DateTime.utc_now()

    %LabelSetting{}
    |> LabelSetting.changeset(%{name: name})
    |> Repo.insert(
      conflict_target: {:unsafe_fragment, "(lower(name))"},
      on_conflict: [set: [updated_at: now]],
      returning: true
    )
  end

  defp async_revalidate_labels(%LabelSetting{} = label_setting) do
    fun = fn -> revalidate_labels(label_setting.id) end

    case Process.whereis(GSMLG.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(GSMLG.TaskSupervisor, fun)
    end
  end

  defp revalidate_labels(label_setting_id) do
    Label
    |> where([label], label.label_setting_id == ^label_setting_id)
    |> preload(:label_setting)
    |> Repo.all()
    |> Enum.each(fn %Label{label_setting: label_setting, value: value} = label ->
      {status, errors} = LabelValue.classify(label_setting, value)

      label
      |> Label.changeset(%{status: status, errors: errors})
      |> Repo.update()
    end)
  end

  defp value_to_string(value), do: LabelValue.normalize(value)

  defp normalize_opts(opts) when is_map(opts) do
    opts
    |> normalize_attrs(@option_keys)
    |> Enum.into([])
  end

  defp normalize_opts(opts), do: opts

  defp normalize_attrs(attrs, allowed_keys) when is_map(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, normalized ->
      case Map.fetch(allowed_keys, key) do
        {:ok, normalized_key} -> Map.put(normalized, normalized_key, value)
        :error -> normalized
      end
    end)
  end

  defp normalize_attrs(attrs, _allowed_keys), do: attrs

  defp reject_attachment_input(attrs) when is_map(attrs) do
    if Map.has_key?(attrs, :attachments) or
         Map.has_key?(attrs, "attachments") do
      {:error, {:attachments, %{code: :not_allowed}}}
    else
      :ok
    end
  end

  defp reject_attachment_input(_attrs), do: {:error, :invalid_attrs}

  defp attachment_update_content(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :update_content) ->
        Map.fetch!(attrs, :update_content)

      Map.has_key?(attrs, "update_content") ->
        Map.fetch!(attrs, "update_content")

      true ->
        false
    end
  end

  defp attachment_update_content(_attrs), do: false

  defp actor_id(actor), do: Audit.actor_id(actor)

  defp preload_note(%Note{} = note),
    do: Repo.preload(note, [labels: :label_setting, attachments: :storage_file], force: true)

  defp update_note_fields_in_repo(note_id, attrs, labels) do
    Repo.transaction(fn ->
      with {:ok, locked_note} <- lock_active_note(note_id) do
        locked_note = preload_labels_for_field_update(locked_note, labels)
        changeset = Note.changeset(locked_note, attrs)
        labels_changed? = labels_changed?(locked_note, labels)

        fields =
          changed_note_fields(changeset) ++
            if(labels_changed?, do: ["labels"], else: [])

        with {:ok, updated} <- Repo.update(changeset),
             {:ok, updated} <-
               replace_changed_labels_in_repo(
                 updated,
                 labels,
                 labels_changed?
               ) do
          {preload_note(updated), fields}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp preload_labels_for_field_update(note, @labels_not_provided), do: note

  defp preload_labels_for_field_update(note, _labels),
    do: Repo.preload(note, labels: :label_setting, force: true)

  defp labels_changed?(_note, @labels_not_provided), do: false

  defp labels_changed?(%Note{labels: labels}, desired_labels) do
    persisted =
      labels
      |> Enum.map(fn label ->
        {
          LabelSetting.normalized_key(label.label_setting.name),
          value_to_string(label.value)
        }
      end)
      |> Enum.sort()

    desired =
      desired_labels
      |> Enum.map(&{&1.normalized_key, value_to_string(&1.value)})
      |> Enum.sort()

    persisted != desired
  end

  defp replace_changed_labels_in_repo(
         %Note{} = note,
         @labels_not_provided,
         false
       ),
       do: {:ok, note}

  defp replace_changed_labels_in_repo(%Note{} = note, _labels, false),
    do: {:ok, note}

  defp replace_changed_labels_in_repo(%Note{} = note, labels, true),
    do: set_labels_in_repo(note, labels)

  defp changed_note_fields(changeset) do
    [:title, :content]
    |> Enum.filter(&Ecto.Changeset.changed?(changeset, &1))
    |> Enum.map(&Atom.to_string/1)
  end

  defp lock_active_note(note_id) do
    active_note_query()
    |> where([note], note.id == ^note_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      note -> {:ok, note}
    end
  end

  defp active_note_query do
    from(n in Note, where: is_nil(n.deleted_at))
  end

  defp deleted_note_query do
    from(n in Note, where: not is_nil(n.deleted_at))
  end

  defp transact_deleted_note(note_id, operation) do
    with {:ok, note_id} <- Ecto.UUID.cast(note_id) do
      Repo.transaction(fn ->
        deleted_note =
          deleted_note_query()
          |> where([note], note.id == ^note_id)
          |> lock("FOR UPDATE")
          |> Repo.one()

        case deleted_note do
          nil ->
            Repo.rollback(:not_found)

          %Note{} = note ->
            note = preload_note(note)

            case operation.(note) do
              {:ok, _result} = result -> result
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, reason} -> {:error, reason}
      end
    else
      :error -> {:error, :not_found}
    end
  end

  defp log_action(action, entity_type, entity_id, note_id, actor, details),
    do: Audit.log(action, entity_type, entity_id, note_id, actor, details)

  defp tap_success({:ok, value} = result, fun) do
    _ = fun.(value)
    result
  end

  defp tap_success(result, _fun), do: result

  defp changed_fields(attrs, allowed_keys, labels \\ @labels_not_provided) do
    fields =
      attrs
      |> normalize_attrs(allowed_keys)
      |> Map.keys()
      |> Enum.map(&to_string/1)

    if labels == @labels_not_provided, do: fields, else: Enum.uniq(fields ++ ["labels"])
  end

  defp hash_api_key(api_key) do
    :sha256
    |> :crypto.hash(api_key)
    |> Base.encode16(case: :lower)
  end

  defp api_key_hint(api_key) do
    case String.length(api_key) do
      length when length <= 10 -> String.duplicate("*", length)
      _length -> "#{String.slice(api_key, 0, 6)}...#{String.slice(api_key, -4, 4)}"
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")
end
