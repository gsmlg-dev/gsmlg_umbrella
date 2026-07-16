defmodule GSMLG.GaoNote do
  @moduledoc """
  Domain context for GaoNote notes, label settings, and storage-backed attachments.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Ecto.Multi
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, MCPSetting, Note}
  alias GSMLG.Repo
  alias GSMLG.Storage

  @default_limit 50
  @max_limit 200
  @labels_not_provided :__gao_note_labels_not_provided__
  @mcp_setting_id "default"
  @note_attr_keys %{
    "title" => :title,
    :title => :title,
    "description" => :description,
    :description => :description,
    "content" => :content,
    :content => :content,
    "labels" => :labels,
    :labels => :labels,
    "tags" => :tags,
    :tags => :tags
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
  @attachment_attr_keys %{
    "note_id" => :note_id,
    :note_id => :note_id,
    "storage_file_id" => :storage_file_id,
    :storage_file_id => :storage_file_id,
    "role" => :role,
    :role => :role,
    "description" => :description,
    :description => :description,
    "path" => :path,
    :path => :path,
    "caption" => :caption,
    :caption => :caption,
    "alt_text" => :alt_text,
    :alt_text => :alt_text,
    "position" => :position,
    :position => :position,
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

    LabelSetting
    |> order_by([t], asc: fragment("lower(?)", t.name))
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def get_label_setting(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(LabelSetting, id)
    else
      :error -> nil
    end
  end

  def get_label_setting!(id), do: Repo.get!(LabelSetting, id)

  def list_attachments(note_id) do
    with {:ok, note_id} <- Ecto.UUID.cast(note_id) do
      Attachment
      |> join(:inner, [attachment], file in assoc(attachment, :storage_file))
      |> join(:inner, [attachment, _file], note in assoc(attachment, :note))
      |> where(
        [attachment, file, note],
        attachment.note_id == ^note_id and file.status == "active" and is_nil(note.deleted_at)
      )
      |> order_by([attachment], asc: attachment.position, asc: attachment.inserted_at)
      |> preload([_attachment, file, _note], storage_file: file)
      |> Repo.all()
    else
      :error -> []
    end
  end

  def list_all_attachments(opts \\ []) do
    opts = normalize_opts(opts)

    Attachment
    |> join(:inner, [attachment], file in assoc(attachment, :storage_file))
    |> join(:inner, [attachment, _file], note in assoc(attachment, :note))
    |> where([_attachment, file, note], file.status == "active" and is_nil(note.deleted_at))
    |> order_by([attachment], desc: attachment.inserted_at, desc: attachment.id)
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload([_attachment, file, note], storage_file: file, note: note)
    |> Repo.all()
  end

  def get_attachment(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Attachment
      |> join(:inner, [attachment], file in assoc(attachment, :storage_file))
      |> join(:inner, [attachment, _file], note in assoc(attachment, :note))
      |> where(
        [attachment, file, note],
        attachment.id == ^id and file.status == "active" and is_nil(note.deleted_at)
      )
      |> preload([_attachment, file, _note], storage_file: file)
      |> Repo.one()
    else
      :error -> nil
    end
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

  def change_attachment(%Attachment{} = attachment, attrs \\ %{}) do
    Attachment.changeset(attachment, normalize_attrs(attrs, @attachment_attr_keys))
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
    Repo.delete(label_setting)
    |> tap_success(fn label_setting ->
      log_action("delete", "label_setting", label_setting.id, nil, actor, %{"name" => label_setting.name})
    end)
  end

  def create_note(attrs, actor) do
    attrs = normalize_attrs(attrs, @note_attr_keys)
    {label_source, label_values, attrs} = pop_labels_input(attrs)

    with {:ok, labels} <- normalize_labels(label_values, label_source) do
      labels = if labels == @labels_not_provided, do: [], else: labels

      Multi.new()
      |> Multi.insert(:note, Note.create_changeset(%Note{}, attrs))
      |> Multi.run(:labels, fn _repo, %{note: note} ->
        set_labels_in_repo(note, labels)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{note: note}} ->
          note = preload_note(note)
          log_action("create", "note", note.id, note.id, actor, %{"title" => note.title})
          {:ok, note}

        {:error, :note, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def update_note(%Note{} = note, attrs, actor) do
    attrs =
      attrs
      |> normalize_attrs(@note_attr_keys)

    {label_source, label_values, attrs} = pop_labels_input(attrs)

    with {:ok, labels} <- normalize_labels(label_values, label_source) do
      Multi.new()
      |> Multi.update(:note, Note.changeset(note, attrs))
      |> maybe_replace_labels(labels)
      |> Repo.transaction()
      |> case do
        {:ok, %{note: note}} ->
          note = preload_note(note)

          log_action("update", "note", note.id, note.id, actor, %{
            "title" => note.title,
            "fields" => changed_fields(attrs, @note_attr_keys, labels)
          })

          {:ok, note}

        {:error, :note, changeset, _changes} ->
          {:error, changeset}

        {:error, _step, reason, _changes} ->
          {:error, reason}
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
      with {:ok, deleted} <- Repo.delete(locked_note),
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

  def attach_existing_file(note_id, storage_file_id, attrs \\ %{}, opts \\ []) do
    with {:ok, note} <- fetch_active_note(note_id),
         {:ok, file} <- fetch_active_storage_file(storage_file_id) do
      insert_attachment(note, file, attrs, attachment_actor(opts))
    end
  end

  def upload_attachment(note_id, upload, attrs \\ %{}, opts \\ []) do
    with {:ok, note} <- fetch_active_note(note_id) do
      attrs = normalize_attrs(attrs, @attachment_attr_keys)
      actor = attachment_actor(opts)
      metadata = Map.get(attrs, :metadata, %{}) |> Map.merge(%{"note_id" => note.id})

      upload_opts = [
        uploaded_by: attachment_option(opts, :uploaded_by) || actor_id(actor),
        metadata: metadata
      ]

      with {:ok, file} <- Storage.upload(upload, "gao_note", "attachment", upload_opts) do
        case insert_attachment(note, file, attrs, actor) do
          {:ok, _attachment} = result ->
            result

          {:error, _reason} = error ->
            cleanup_uploaded_file(file)
            error
        end
      end
    end
  end

  defp cleanup_uploaded_file(file) do
    case Storage.delete(file) do
      {:ok, _deleted_file} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "Failed to deactivate storage file #{file.id} after attachment insertion failed: #{inspect(reason)}"
        )

        :ok
    end
  end

  def update_attachment(note_id, attachment_id, attrs) do
    with {:ok, attachment} <- fetch_attachment_for_active_note(note_id, attachment_id) do
      attachment
      |> Attachment.changeset(normalize_attrs(attrs, @attachment_attr_keys))
      |> Repo.update()
      |> case do
        {:ok, attachment} ->
          log_action("update", "attachment", attachment.id, attachment.note_id, nil, %{
            "fields" => changed_fields(attrs, @attachment_attr_keys)
          })

          {:ok, Repo.preload(attachment, :storage_file, force: true)}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  def detach_attachment(note_id, attachment_id) do
    with {:ok, attachment} <- fetch_attachment_for_active_note(note_id, attachment_id) do
      Repo.delete(attachment)
      |> tap_success(fn attachment ->
        log_action("delete", "attachment", attachment.id, attachment.note_id, nil, %{
          "storage_file_id" => attachment.storage_file_id,
          "role" => attachment.role
        })
      end)
    end
  end

  defp insert_attachment(note, file, attrs, actor) do
    attrs =
      attrs
      |> normalize_attrs(@attachment_attr_keys)
      |> Map.put(:note_id, note.id)
      |> Map.put(:storage_file_id, file.id)

    %Attachment{}
    |> Attachment.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, attachment} ->
        log_action("create", "attachment", attachment.id, note.id, actor, %{
          "storage_file_id" => file.id,
          "role" => attachment.role
        })

        {:ok, Repo.preload(attachment, :storage_file)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp fetch_active_note(note_id) do
    with {:ok, note_id} <- Ecto.UUID.cast(note_id),
         %Note{} = note <- Repo.get(active_note_query(), note_id) do
      {:ok, note}
    else
      _reason -> {:error, :not_found}
    end
  end

  defp fetch_active_storage_file(storage_file_id) do
    with {:ok, storage_file_id} <- Ecto.UUID.cast(storage_file_id),
         %{id: ^storage_file_id} = file <- Storage.get_active(storage_file_id) do
      {:ok, file}
    else
      _reason -> {:error, :storage_file_not_active}
    end
  end

  defp fetch_attachment_for_active_note(note_id, attachment_id) do
    with {:ok, note_id} <- Ecto.UUID.cast(note_id),
         {:ok, attachment_id} <- Ecto.UUID.cast(attachment_id),
         %Attachment{} = attachment <-
           Attachment
           |> join(:inner, [attachment], note in assoc(attachment, :note))
           |> where(
             [attachment, note],
             attachment.id == ^attachment_id and attachment.note_id == ^note_id and
               is_nil(note.deleted_at)
           )
           |> preload(:storage_file)
           |> Repo.one() do
      {:ok, attachment}
    else
      _reason -> {:error, :not_found}
    end
  end

  defp attachment_actor(opts) do
    case attachment_option(opts, :actor) do
      nil when is_map(opts) ->
        if Map.has_key?(opts, :id) or Map.has_key?(opts, "id"), do: opts, else: nil

      actor ->
        actor
    end
  end

  defp attachment_option(opts, key) when is_list(opts), do: Keyword.get(opts, key)

  defp attachment_option(opts, key) when is_map(opts) do
    Map.get(opts, key) || Map.get(opts, Atom.to_string(key))
  end

  defp attachment_option(_opts, _key), do: nil

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
      ilike(n.title, ^pattern) or ilike(n.description, ^pattern) or ilike(n.content, ^pattern)
    )
  end

  defp filter_by_label(query, nil), do: query
  defp filter_by_label(query, ""), do: query

  defp filter_by_label(query, label_filter) do
    case normalize_label_filter(label_filter) do
      {:ok, label_key, nil} ->
        query
        |> join(:inner, [n], label in assoc(n, :labels), as: :filter_labels)
        |> join(:inner, [filter_labels: label], t in assoc(label, :label_setting),
          as: :filter_label_settings
        )
        |> where([filter_label_settings: t], fragment("lower(?)", t.name) == ^label_key)

      {:ok, label_key, value} ->
        query
        |> join(:inner, [n], label in assoc(n, :labels), as: :filter_labels)
        |> join(:inner, [filter_labels: label], t in assoc(label, :label_setting), as: :filter_label_settings)
        |> where([filter_label_settings: t], fragment("lower(?)", t.name) == ^label_key)
        |> where([filter_labels: label], label.value == ^value)

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

  defp maybe_replace_labels(multi, @labels_not_provided), do: multi

  defp maybe_replace_labels(multi, labels) do
    Multi.run(multi, :labels, fn _repo, %{note: note} ->
      set_labels_in_repo(note, labels)
    end)
  end

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
        {status, errors} = validate_label_value(label_setting, label.value)

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

  defp validate_label_value(%LabelSetting{value_type: value_type}, value) do
    value = value_to_string(value)
    value_type = value_type || "text"

    case value_type do
      "text" -> valid_label()
      "number" -> validate_number_label(value)
      "version" -> validate_version_label(value)
      "date" -> validate_date_label(value)
      "date-time" -> validate_datetime_label(value)
      "time" -> validate_time_label(value)
      "year" -> validate_regex_label(value, ~r/^\d{4}$/, "must be YYYY")
      "year-month" -> validate_regex_label(value, ~r/^\d{4}-(0[1-9]|1[0-2])$/, "must be YYYY-MM")
      "year-season" -> validate_regex_label(value, ~r/^\d{4}-Q[1-4]$/, "must be YYYY-Q1..YYYY-Q4")
      _other -> invalid_label("unsupported value type #{value_type}")
    end
  end

  defp validate_number_label(value) do
    case Float.parse(value) do
      {_number, ""} -> valid_label()
      _other -> invalid_label("must be a number")
    end
  end

  defp validate_version_label(value) do
    if Regex.match?(~r/^v?\d+(\.\d+){0,3}([+-][0-9A-Za-z.-]+)?$/, value) do
      valid_label()
    else
      invalid_label("must be a version")
    end
  end

  defp validate_date_label(value) do
    case Date.from_iso8601(value) do
      {:ok, _date} -> valid_label()
      {:error, _reason} -> invalid_label("must be YYYY-MM-DD")
    end
  end

  defp validate_datetime_label(value) do
    cond do
      match?({:ok, _datetime, _offset}, DateTime.from_iso8601(value)) ->
        valid_label()

      match?({:ok, _datetime}, NaiveDateTime.from_iso8601(value)) ->
        valid_label()

      true ->
        invalid_label("must be ISO8601 date-time")
    end
  end

  defp validate_time_label(value) do
    case Time.from_iso8601(value) do
      {:ok, _time} -> valid_label()
      {:error, _reason} -> invalid_label("must be ISO8601 time")
    end
  end

  defp validate_regex_label(value, regex, message) do
    if Regex.match?(regex, value), do: valid_label(), else: invalid_label(message)
  end

  defp valid_label, do: {"valid", []}
  defp invalid_label(message), do: {"invalid", [message]}

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
      {status, errors} = validate_label_value(label_setting, value)

      label
      |> Label.changeset(%{status: status, errors: errors})
      |> Repo.update()
    end)
  end

  defp value_to_string(nil), do: ""
  defp value_to_string(value) when is_binary(value), do: String.trim(value)
  defp value_to_string(value), do: value |> to_string() |> String.trim()

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

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(%{id: id}), do: to_string(id)
  defp actor_id(_actor), do: nil

  defp actor_source(actor) do
    case actor do
      %{source: source} when is_binary(source) and source != "" -> source
      %{"source" => source} when is_binary(source) and source != "" -> source
      _ -> "admin"
    end
  end

  defp preload_note(%Note{} = note),
    do: Repo.preload(note, [labels: :label_setting, attachments: :storage_file], force: true)

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

  defp log_action(action, entity_type, entity_id, note_id, actor, details) do
    %Log{}
    |> Log.changeset(%{
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      note_id: note_id,
      actor_id: actor_id(actor),
      source: actor_source(actor),
      details: details || %{}
    })
    |> Repo.insert()
  end

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
