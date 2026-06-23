defmodule GSMLG.GaoNote do
  @moduledoc """
  Domain context for GaoNote notes, tags, web references, and storage-backed assets.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias GSMLG.GaoNote.{Asset, Log, MCPSetting, Note, Reference, Tag}
  alias GSMLG.Repo
  alias GSMLG.Storage

  @default_limit 50
  @max_limit 200
  @mcp_setting_id "default"

  def public_note_query do
    from(n in Note)
  end

  def list_notes(opts \\ []) do
    opts = normalize_opts(opts)

    Note
    |> filter_by_creator(opts[:creator])
    |> filter_by_search(opts[:search])
    |> filter_by_tag(opts[:tag])
    |> apply_order(opts[:order_by])
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload([:tags])
    |> Repo.all()
  end

  def search_notes(query, opts \\ []) do
    opts
    |> Keyword.put(:search, query)
    |> list_notes()
  end

  def get_note(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Note
      |> preload([:tags])
      |> Repo.get(id)
    else
      :error -> nil
    end
  end

  def get_note!(id) do
    Note
    |> preload([:tags])
    |> Repo.get!(id)
  end

  def get_public_note(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      public_note_query()
      |> where([n], n.id == ^id)
      |> preload([:tags])
      |> Repo.one()
    else
      :error -> nil
    end
  end

  def list_tags(opts \\ []) do
    limit = Keyword.get(opts, :limit)

    Tag
    |> order_by([t], asc: fragment("lower(?)", t.name))
    |> maybe_limit(limit)
    |> Repo.all()
  end

  def get_tag(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(Tag, id)
    else
      :error -> nil
    end
  end

  def get_tag!(id), do: Repo.get!(Tag, id)

  def list_references(note_or_id) do
    note_id = note_id(note_or_id)

    Reference
    |> where([r], r.note_id == ^note_id)
    |> order_by([r], asc: r.position, asc: r.inserted_at)
    |> Repo.all()
  end

  def list_all_references(opts \\ []) do
    opts = normalize_opts(opts)

    Reference
    |> order_by([r], desc: r.inserted_at)
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload(:note)
    |> Repo.all()
  end

  def get_reference(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Repo.get(Reference, id)
    else
      :error -> nil
    end
  end

  def list_assets(note_or_id) do
    note_id = note_id(note_or_id)

    Asset
    |> join(:inner, [a], f in assoc(a, :storage_file))
    |> where([a, f], a.note_id == ^note_id and f.status == "active")
    |> order_by([a], asc: a.position, asc: a.inserted_at)
    |> preload([_a, f], storage_file: f)
    |> Repo.all()
  end

  def list_all_assets(opts \\ []) do
    opts = normalize_opts(opts)

    Asset
    |> join(:inner, [a], f in assoc(a, :storage_file))
    |> join(:inner, [a, _f], n in assoc(a, :note))
    |> where([_a, f, _n], f.status == "active")
    |> order_by([a], desc: a.inserted_at)
    |> limit(^limit_value(opts[:limit]))
    |> offset(^offset_value(opts[:offset]))
    |> preload([_a, f, n], storage_file: f, note: n)
    |> Repo.all()
  end

  def get_asset(id) do
    with {:ok, id} <- Ecto.UUID.cast(id) do
      Asset
      |> preload(:storage_file)
      |> Repo.get(id)
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
    Note.changeset(note, attrs)
  end

  def change_reference(%Reference{} = reference, attrs \\ %{}) do
    Reference.changeset(reference, attrs)
  end

  def change_asset(%Asset{} = asset, attrs \\ %{}) do
    Asset.changeset(asset, attrs)
  end

  def change_tag(%Tag{} = tag, attrs \\ %{}) do
    Tag.changeset(tag, attrs)
  end

  def create_tag(attrs, actor \\ nil) do
    %Tag{}
    |> Tag.changeset(normalize_attrs(attrs))
    |> Repo.insert()
    |> tap_success(fn tag ->
      log_action("create", "tag", tag.id, nil, actor, %{"name" => tag.name})
    end)
  end

  def update_tag(%Tag{} = tag, attrs, actor \\ nil) do
    tag
    |> Tag.changeset(normalize_attrs(attrs))
    |> Repo.update()
    |> tap_success(fn tag ->
      log_action("update", "tag", tag.id, nil, actor, %{
        "name" => tag.name,
        "fields" => changed_fields(attrs)
      })
    end)
  end

  def delete_tag(%Tag{} = tag, actor \\ nil) do
    Repo.delete(tag)
    |> tap_success(fn tag ->
      log_action("delete", "tag", tag.id, nil, actor, %{"name" => tag.name})
    end)
  end

  def create_note(attrs, actor) do
    attrs = normalize_attrs(attrs)
    {tag_names, attrs} = Map.pop(attrs, :tags, [])
    {reference_attrs, attrs} = Map.pop(attrs, :references, [])

    Multi.new()
    |> Multi.insert(:note, Note.create_changeset(%Note{}, attrs))
    |> Multi.run(:tags, fn _repo, %{note: note} ->
      replace_tags_in_repo(note, tag_names)
    end)
    |> Multi.run(:references, fn _repo, %{note: note} ->
      add_references_in_repo(note, List.wrap(reference_attrs))
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

  def update_note(%Note{} = note, attrs, actor) do
    attrs =
      attrs
      |> normalize_attrs()

    {tag_names, attrs} = Map.pop(attrs, :tags, :not_provided)

    Multi.new()
    |> Multi.update(:note, Note.changeset(note, attrs))
    |> maybe_replace_tags(tag_names)
    |> Repo.transaction()
    |> case do
      {:ok, %{note: note}} ->
        note = preload_note(note)

        log_action("update", "note", note.id, note.id, actor, %{
          "title" => note.title,
          "fields" => changed_fields(attrs, tag_names)
        })

        {:ok, note}

      {:error, :note, changeset, _changes} ->
        {:error, changeset}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def delete_note(%Note{} = note, actor) do
    Repo.delete(note)
    |> tap_success(fn deleted ->
      log_action("delete", "note", deleted.id, deleted.id, actor, %{"title" => deleted.title})
    end)
  end

  def replace_tags(%Note{} = note, tag_names, actor) do
    Multi.new()
    |> Multi.run(:tags, fn _repo, _changes -> replace_tags_in_repo(note, tag_names) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{tags: note}} ->
        note = preload_note(note)

        log_action("update", "note", note.id, note.id, actor, %{
          "title" => note.title,
          "fields" => ["tags"]
        })

        {:ok, note}

      {:error, :tags, reason, _changes} ->
        {:error, reason}
    end
  end

  def add_reference(%Note{} = note, attrs, actor) do
    attrs =
      attrs
      |> normalize_attrs()
      |> Map.put(:note_id, note.id)

    %Reference{}
    |> Reference.changeset(attrs)
    |> Repo.insert()
    |> tap_success(fn reference ->
      log_action("create", "reference", reference.id, note.id, actor, %{
        "title" => reference.title,
        "url" => reference.url
      })
    end)
  end

  def update_reference(%Reference{} = reference, attrs, actor) do
    reference
    |> Reference.changeset(normalize_attrs(attrs))
    |> Repo.update()
    |> tap_success(fn reference ->
      log_action("update", "reference", reference.id, reference.note_id, actor, %{
        "title" => reference.title,
        "fields" => changed_fields(attrs)
      })
    end)
  end

  def remove_reference(%Reference{} = reference, actor) do
    Repo.delete(reference)
    |> tap_success(fn reference ->
      log_action("delete", "reference", reference.id, reference.note_id, actor, %{
        "title" => reference.title,
        "url" => reference.url
      })
    end)
  end

  def attach_asset(%Note{} = note, storage_file_id, attrs, actor) do
    case Storage.get_active(storage_file_id) do
      nil ->
        {:error, :storage_file_not_active}

      _file ->
        attrs =
          attrs
          |> normalize_attrs()
          |> Map.put(:note_id, note.id)
          |> Map.put(:storage_file_id, storage_file_id)

        %Asset{}
        |> Asset.changeset(attrs)
        |> Repo.insert()
        |> case do
          {:ok, asset} ->
            log_action("create", "asset", asset.id, note.id, actor, %{
              "storage_file_id" => storage_file_id,
              "role" => asset.role
            })

            {:ok, Repo.preload(asset, :storage_file)}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def upload_asset(%Note{} = note, upload_input, attrs, actor) do
    metadata =
      attrs
      |> normalize_attrs()
      |> Map.get(:metadata, %{})
      |> Map.merge(%{"note_id" => note.id})

    with {:ok, file} <-
           Storage.upload(upload_input, "gao_note", "asset",
             uploaded_by: actor_id(actor),
             metadata: metadata
           ) do
      attach_asset(note, file.id, attrs, actor)
    end
  end

  def update_asset(%Asset{} = asset, attrs, actor) do
    asset
    |> Asset.changeset(normalize_attrs(attrs))
    |> Repo.update()
    |> case do
      {:ok, asset} ->
        log_action("update", "asset", asset.id, asset.note_id, actor, %{
          "fields" => changed_fields(attrs)
        })

        {:ok, Repo.preload(asset, :storage_file)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def detach_asset(%Asset{} = asset, actor) do
    Repo.delete(asset)
    |> tap_success(fn asset ->
      log_action("delete", "asset", asset.id, asset.note_id, actor, %{
        "storage_file_id" => asset.storage_file_id,
        "role" => asset.role
      })
    end)
  end

  defp filter_by_creator(query, nil), do: query
  defp filter_by_creator(query, ""), do: query
  defp filter_by_creator(query, creator), do: where(query, [n], n.creator == ^creator)

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

  defp filter_by_tag(query, nil), do: query
  defp filter_by_tag(query, ""), do: query

  defp filter_by_tag(query, tag) do
    tag_key = Tag.normalized_key(tag)

    if blank?(tag_key) do
      query
    else
      query
      |> join(:inner, [n], t in assoc(n, :tags), as: :filter_tags)
      |> where([filter_tags: t], fragment("lower(?)", t.name) == ^tag_key)
    end
  end

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

  defp maybe_replace_tags(multi, :not_provided), do: multi

  defp maybe_replace_tags(multi, tag_names) do
    Multi.run(multi, :tags, fn _repo, %{note: note} ->
      replace_tags_in_repo(note, tag_names)
    end)
  end

  defp replace_tags_in_repo(%Note{} = note, tag_names) do
    with {:ok, tag_names} <- normalize_tag_names(tag_names),
         {:ok, tags} <- get_or_insert_tags(tag_names) do
      note = Repo.preload(note, :tags)

      note
      |> Ecto.Changeset.change()
      |> Ecto.Changeset.put_assoc(:tags, tags)
      |> Repo.update()
    end
  end

  defp add_references_in_repo(%Note{} = note, reference_attrs) do
    Enum.reduce_while(reference_attrs, {:ok, []}, fn attrs, {:ok, references} ->
      case add_reference(note, attrs, nil) do
        {:ok, reference} -> {:cont, {:ok, [reference | references]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize_tag_names(nil), do: {:ok, []}

  defp normalize_tag_names(tag_names) when is_list(tag_names) do
    if Enum.all?(tag_names, &is_binary/1) do
      tag_names =
        tag_names
        |> Enum.map(&Tag.normalize_display_name/1)
        |> Enum.reject(&blank?/1)
        |> Enum.uniq_by(&Tag.normalized_key/1)

      {:ok, tag_names}
    else
      {:error, "tags must be an array of strings"}
    end
  end

  defp normalize_tag_names(_tag_names), do: {:error, "tags must be an array of strings"}

  defp get_or_insert_tags(tag_names) do
    tag_names
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, tags} ->
      case get_or_insert_tag(name) do
        {:ok, tag} -> {:cont, {:ok, [tag | tags]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tags} -> {:ok, Enum.sort_by(tags, &Tag.normalized_key(&1.name))}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_or_insert_tag(name) do
    tag_key = Tag.normalized_key(name)

    case tag_by_normalized_name(tag_key) do
      %Tag{} = tag ->
        {:ok, tag}

      nil ->
        insert_tag(name)
    end
  end

  defp tag_by_normalized_name(tag_key) do
    Tag
    |> where([t], fragment("lower(?)", t.name) == ^tag_key)
    |> Repo.one()
  end

  defp insert_tag(name) do
    now = DateTime.utc_now()

    %Tag{}
    |> Tag.changeset(%{name: name})
    |> Repo.insert(
      conflict_target: {:unsafe_fragment, "(lower(name))"},
      on_conflict: [set: [updated_at: now]],
      returning: true
    )
  end

  defp normalize_opts(opts) when is_map(opts), do: Enum.into(opts, [])
  defp normalize_opts(opts), do: opts

  defp normalize_attrs(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize_attrs(attrs), do: attrs

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

  defp note_id(%Note{id: id}), do: id
  defp note_id(id), do: id

  defp preload_note(%Note{} = note), do: Repo.preload(note, [:tags], force: true)

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

  defp changed_fields(attrs, tag_names \\ :not_provided) do
    fields =
      attrs
      |> normalize_attrs()
      |> Map.keys()
      |> Enum.map(&to_string/1)

    if tag_names == :not_provided, do: fields, else: Enum.uniq(fields ++ ["tags"])
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
