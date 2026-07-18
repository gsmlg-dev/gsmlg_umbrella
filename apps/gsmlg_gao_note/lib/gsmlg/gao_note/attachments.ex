defmodule GSMLG.GaoNote.Attachments do
  @moduledoc false

  import Ecto.Query, warn: false

  require Logger

  alias GSMLG.GaoNote.{Attachment, AttachmentInput, Note}
  alias GSMLG.GaoNote.Workers.StorageFilePurgeWorker
  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  @storage_type "gao_note_attachment"

  def prepare(note_id, raw_inputs, uploaded_by) when is_list(raw_inputs) do
    with {:ok, note_id} <- cast_note_id(note_id),
         {:ok, inputs} <- cast_inputs(raw_inputs),
         :ok <- validate_unique_inputs(inputs),
         current <- current_attachments(note_id),
         :ok <- ensure_ids_available(note_id, inputs),
         {:ok, entries} <- build_entries(inputs, current),
         :ok <- ensure_external_transaction_supported(entries) do
      stage_entries(note_id, entries, current, uploaded_by)
    end
  end

  def prepare(_note_id, _raw_inputs, _uploaded_by) do
    {:error, {:attachments, %{code: :must_be_a_list}}}
  end

  def reconcile(note_id, %{note_id: note_id} = plan) do
    desired_ids = MapSet.new(plan.entries, & &1.input.id)

    with :ok <- lock_attachment_ids(plan.entries),
         current <- lock_current_attachments(note_id),
         :ok <- ensure_snapshot_unchanged(plan.snapshot, current),
         :ok <- ensure_ids_available_locked(note_id, plan.entries),
         purge_ids <- purge_storage_file_ids(current, plan.entries, desired_ids),
         {:ok, remaining} <- remove_missing(current, desired_ids),
         {:ok, moved} <- temporarily_move_paths(remaining),
         {:ok, attachments} <- persist_entries(note_id, plan.entries, moved),
         {:ok, _jobs} <- schedule_purges(purge_ids) do
      {:ok, attachments}
    end
  end

  def reconcile(_note_id, _plan), do: {:error, :invalid_attachment_plan}

  def cleanup(%{staged_files: staged_files}) when is_list(staged_files) do
    cleanup_files(staged_files)
  end

  def cleanup(_plan), do: :ok

  def transact(plan, operation) when is_function(operation, 0) do
    try do
      case Repo.transaction(operation) do
        {:ok, _result} = success ->
          success

        {:error, _reason} = error ->
          cleanup(plan)
          error
      end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        cleanup(plan)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  def schedule_purges(storage_file_ids) when is_list(storage_file_ids) do
    storage_file_ids
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn storage_file_id, {:ok, jobs} ->
      storage_file_id
      |> then(&StorageFilePurgeWorker.new(%{storage_file_id: &1}))
      |> Oban.insert()
      |> case do
        {:ok, job} -> {:cont, {:ok, [job | jobs]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def get_by_path(note_id, path) do
    get_by_path(note_id, path, :active)
  end

  def get_deleted_by_path(note_id, path) do
    get_by_path(note_id, path, :deleted)
  end

  def read_text(note_id, attachment_id) do
    with {:ok, note_id} <- cast_note_id(note_id),
         :ok <- validate_attachment_id(attachment_id),
         %Attachment{} = attachment <-
           attachment_query()
           |> where(
             [attachment, _note, _file],
             attachment.note_id == ^note_id and attachment.id == ^attachment_id
           )
           |> active_scope()
           |> preload([_attachment, _note, file], storage_file: file)
           |> Repo.one(),
         {:ok, bytes} <- read_storage_file(attachment.storage_file),
         :ok <- validate_text(bytes) do
      {:ok, bytes}
    else
      nil -> {:error, :not_found}
      {:error, :invalid_note_id} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp cast_inputs(raw_inputs) do
    raw_inputs
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attrs, index}, {:ok, inputs} ->
      case AttachmentInput.cast(attrs) do
        {:ok, %AttachmentInput{upload: nil} = input} ->
          {:cont, {:ok, [input | inputs]}}

        {:ok, %AttachmentInput{bytes: nil, upload: %Plug.Upload{}} = input} ->
          {:cont, {:ok, [input | inputs]}}

        {:ok, %AttachmentInput{id: id, upload: %Plug.Upload{}}} ->
          {:halt,
           {:error,
            {:attachment, %{code: :multiple_content_sources, id: id}}}}

        {:ok, %AttachmentInput{id: id}} ->
          {:halt,
           {:error,
            {:attachment, %{code: :unsupported_content_source, id: id}}}}

        {:error, changeset} ->
          {:halt,
           {:error,
            {:attachment_input, %{code: :invalid, index: index, changeset: changeset}}}}
      end
    end)
    |> case do
      {:ok, inputs} -> {:ok, Enum.reverse(inputs)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_unique_inputs(inputs) do
    case duplicate_value(inputs, & &1.id) do
      nil ->
        validate_unique_paths(inputs)

      id ->
        {:error, {:attachments, %{code: :duplicate_id, id: id}}}
    end
  end

  defp validate_unique_paths(inputs) do
    case duplicate_value(inputs, & &1.path) do
      nil -> :ok
      path -> {:error, {:attachments, %{code: :duplicate_path, path: path}}}
    end
  end

  defp duplicate_value(values, mapper), do: duplicate_value(values, mapper, MapSet.new())
  defp duplicate_value([], _mapper, _seen), do: nil

  defp duplicate_value([value | rest], mapper, seen) do
    key = mapper.(value)

    if MapSet.member?(seen, key) do
      key
    else
      duplicate_value(rest, mapper, MapSet.put(seen, key))
    end
  end

  defp current_attachments(note_id) do
    Attachment
    |> where([attachment], attachment.note_id == ^note_id)
    |> Repo.all()
  end

  defp ensure_ids_available(_note_id, []), do: :ok

  defp ensure_ids_available(note_id, inputs) do
    ids = Enum.map(inputs, & &1.id)

    Attachment
    |> where(
      [attachment],
      attachment.id in ^ids and attachment.note_id != ^note_id
    )
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        :ok

      attachment ->
        {:error,
         {:attachment,
          %{
            code: :owned_by_another_note,
            id: attachment.id,
            owner_note_id: attachment.note_id
          }}}
    end
  end

  defp build_entries(inputs, current) do
    current_by_id = Map.new(current, &{&1.id, &1})

    Enum.reduce_while(inputs, {:ok, []}, fn input, {:ok, entries} ->
      existing = Map.get(current_by_id, input.id)

      case build_entry(input, existing) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp build_entry(input, nil) do
    case content_kind(input) do
      :none ->
        attachment_error(input.id, :content_required)

      :content ->
        {:ok, %{input: input, kind: :insert, staged_file: nil}}
    end
  end

  defp build_entry(input, %Attachment{} = existing) do
    case content_kind(input) do
      :none when input.mime == existing.mime ->
        {:ok, %{input: input, kind: :retain, staged_file: nil}}

      :none ->
        attachment_error(input.id, :retained_mime_mismatch, %{
          submitted: input.mime,
          persisted: existing.mime
        })

      :content ->
        {:ok, %{input: input, kind: :replace, staged_file: nil}}
    end
  end

  defp content_kind(%AttachmentInput{bytes: nil, upload: nil}), do: :none
  defp content_kind(%AttachmentInput{}), do: :content

  defp ensure_external_transaction_supported(entries) do
    if Repo.in_transaction?() and Enum.any?(entries, &(&1.kind in [:insert, :replace])) do
      {:error, {:attachments, %{code: :external_transaction_not_supported}}}
    else
      :ok
    end
  end

  defp stage_entries(note_id, entries, current, uploaded_by) do
    do_stage_entries(entries, note_id, current, uploaded_by, [], [])
  end

  defp do_stage_entries(
         [],
         note_id,
         current,
         _uploaded_by,
         prepared,
         staged_files
       ) do
    {:ok,
     %{
       note_id: note_id,
       entries: Enum.reverse(prepared),
       snapshot: attachment_snapshot(current),
       staged_files: Enum.reverse(staged_files)
     }}
  end

  defp do_stage_entries(
         [entry | rest],
         note_id,
         current,
         uploaded_by,
         prepared,
         staged_files
       ) do
    case stage_entry_safely(note_id, entry, uploaded_by, staged_files) do
      {:ok, prepared_entry, nil} ->
        do_stage_entries(
          rest,
          note_id,
          current,
          uploaded_by,
          [prepared_entry | prepared],
          staged_files
        )

      {:ok, prepared_entry, file} ->
        do_stage_entries(
          rest,
          note_id,
          current,
          uploaded_by,
          [prepared_entry | prepared],
          [file | staged_files]
        )

      {:error, reason, extra_files} ->
        cleanup_files(extra_files ++ staged_files)
        {:error, reason}
    end
  end

  defp stage_entry_safely(note_id, entry, uploaded_by, staged_files) do
    try do
      stage_entry(note_id, entry, uploaded_by)
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        cleanup_files(staged_files)
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp stage_entry(_note_id, %{kind: :retain} = entry, _uploaded_by),
    do: {:ok, entry, nil}

  defp stage_entry(note_id, entry, uploaded_by) do
    input = entry.input

    case storage_source(input) do
      {:ok, source} ->
        upload_staged_file(note_id, entry, source, uploaded_by)

      {:error, reason} ->
        {:error,
         {:attachment, %{code: :content_read_failed, id: input.id, reason: reason}}, []}
    end
  end

  defp upload_staged_file(note_id, entry, source, uploaded_by) do
    input = entry.input

    opts = [
      uploaded_by: uploaded_by,
      metadata: %{"attachment_id" => input.id, "note_id" => note_id},
      variants: []
    ]

    case Storage.upload(source, note_id, @storage_type, opts) do
      {:ok, %StorageFile{} = file} ->
        finish_staged_upload(entry, file)

      {:error, reason} ->
        {:error,
         {:attachment, %{code: :staging_failed, id: input.id, reason: reason}}, []}
    end
  end

  defp finish_staged_upload(entry, file) do
    try do
      if file.content_type == entry.input.mime do
        {:ok, %{entry | staged_file: file}, file}
      else
        error =
          {:attachment,
           %{
             code: :mime_mismatch,
             id: entry.input.id,
             submitted: entry.input.mime,
             detected: file.content_type
           }}

        {:error, error, [file]}
      end
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        cleanup_files([file])
        :erlang.raise(kind, reason, stacktrace)
    end
  end

  defp storage_source(%AttachmentInput{bytes: bytes, upload: nil, path: path})
       when is_binary(bytes) do
    {:ok, {Path.basename(path), bytes}}
  end

  defp storage_source(%AttachmentInput{bytes: nil, upload: %Plug.Upload{} = upload}) do
    {:ok, upload}
  end

  defp lock_current_attachments(note_id) do
    Attachment
    |> where([attachment], attachment.note_id == ^note_id)
    |> lock("FOR UPDATE")
    |> Repo.all()
  end

  defp lock_attachment_ids(entries) do
    entries
    |> Enum.map(& &1.input.id)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while(:ok, fn attachment_id, :ok ->
      case Ecto.Adapters.SQL.query(
             Repo,
             "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
             [attachment_id]
           ) do
        {:ok, _result} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ensure_snapshot_unchanged(snapshot, current) do
    current_snapshot = attachment_snapshot(current)

    if current_snapshot == snapshot do
      :ok
    else
      {:error, {:attachments, %{code: :stale}}}
    end
  end

  defp attachment_snapshot(attachments) do
    Map.new(attachments, fn attachment ->
      {attachment.id,
       %{
         id: attachment.id,
         path: attachment.path,
         mime: attachment.mime,
         description: attachment.description,
         storage_file_id: attachment.storage_file_id,
         inserted_at: attachment.inserted_at,
         updated_at: attachment.updated_at
       }}
    end)
  end

  defp ensure_ids_available_locked(_note_id, []), do: :ok

  defp ensure_ids_available_locked(note_id, entries) do
    ids = Enum.map(entries, & &1.input.id)

    Attachment
    |> where(
      [attachment],
      attachment.id in ^ids and attachment.note_id != ^note_id
    )
    |> lock("FOR UPDATE")
    |> limit(1)
    |> Repo.one()
    |> case do
      nil ->
        :ok

      attachment ->
        {:error,
         {:attachment,
          %{
            code: :owned_by_another_note,
            id: attachment.id,
            owner_note_id: attachment.note_id
          }}}
    end
  end

  defp purge_storage_file_ids(current, entries, desired_ids) do
    current_by_id = Map.new(current, &{&1.id, &1})

    removed =
      for attachment <- current,
          not MapSet.member?(desired_ids, attachment.id),
          do: attachment.storage_file_id

    replaced =
      for %{kind: :replace, input: input} <- entries,
          attachment = Map.fetch!(current_by_id, input.id),
          do: attachment.storage_file_id

    Enum.uniq(removed ++ replaced)
  end

  defp remove_missing(current, desired_ids) do
    Enum.reduce_while(current, {:ok, %{}}, fn attachment, {:ok, remaining} ->
      if MapSet.member?(desired_ids, attachment.id) do
        {:cont, {:ok, Map.put(remaining, attachment.id, attachment)}}
      else
        case Repo.delete(attachment) do
          {:ok, _attachment} -> {:cont, {:ok, remaining}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end
    end)
  end

  defp temporarily_move_paths(attachments) do
    Enum.reduce_while(attachments, {:ok, %{}}, fn {id, attachment}, {:ok, moved} ->
      temporary_path = "./.gao-note-reconcile/#{Ecto.UUID.generate()}"

      attachment
      |> Ecto.Changeset.change(path: temporary_path)
      |> Repo.update()
      |> case do
        {:ok, attachment} -> {:cont, {:ok, Map.put(moved, id, attachment)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_entries(note_id, entries, existing_by_id) do
    Enum.reduce_while(entries, {:ok, []}, fn entry, {:ok, attachments} ->
      input = entry.input
      attachment = Map.get(existing_by_id, input.id, %Attachment{})

      attrs = %{
        id: input.id,
        note_id: note_id,
        storage_file_id: storage_file_id(entry, attachment),
        path: input.path,
        mime: input.mime,
        description: input.description
      }

      attachment
      |> Attachment.changeset(attrs)
      |> Repo.insert_or_update()
      |> case do
        {:ok, attachment} -> {:cont, {:ok, [attachment | attachments]}}

        {:error, %Ecto.Changeset{} = changeset} ->
          reason = translate_persistence_error(note_id, input.id, changeset)
          {:halt, {:error, reason}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attachments} -> {:ok, Enum.reverse(attachments)}
      {:error, _reason} = error -> error
    end
  end

  defp storage_file_id(%{staged_file: %StorageFile{id: id}}, _attachment), do: id
  defp storage_file_id(%{kind: :retain}, %Attachment{storage_file_id: id}), do: id

  defp translate_persistence_error(note_id, attachment_id, changeset) do
    if unique_id_error?(changeset) do
      case Repo.get(Attachment, attachment_id) do
        %Attachment{note_id: owner_note_id} when owner_note_id != note_id ->
          {:attachment,
           %{
             code: :owned_by_another_note,
             id: attachment_id,
             owner_note_id: owner_note_id
           }}

        _attachment ->
          changeset
      end
    else
      changeset
    end
  end

  defp unique_id_error?(changeset) do
    case Keyword.get(changeset.errors, :id) do
      {_message, metadata} -> Keyword.get(metadata, :constraint) == :unique
      nil -> false
    end
  end

  defp cleanup_files(files) do
    Enum.each(files, &cleanup_file_safely/1)
    :ok
  end

  defp cleanup_file_safely(%StorageFile{} = file) do
    try do
      cleanup_file(file)
    catch
      kind, reason ->
        log_cleanup_failure(file.id, {kind, reason})
        :ok
    end
  end

  defp cleanup_file(%StorageFile{} = file) do
    case Storage.delete(file) do
      {:ok, deleted} ->
        case Storage.purge(deleted) do
          {:ok, _purged} -> :ok
          {:error, :not_found} -> :ok
          {:error, reason} -> log_cleanup_failure(file.id, reason)
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        log_cleanup_failure(file.id, reason)
    end
  end

  defp log_cleanup_failure(storage_file_id, reason) do
    Logger.warning(
      "Failed to clean staged GaoNote storage file #{storage_file_id}: #{inspect(reason)}"
    )
  end

  defp get_by_path(note_id, path, scope) do
    with {:ok, note_id} <- cast_note_id(note_id),
         {:ok, path} <- Attachment.normalize_path(path),
         %Attachment{} = attachment <-
           attachment_query()
           |> where(
             [attachment, _note, _file],
             attachment.note_id == ^note_id and attachment.path == ^path
           )
           |> note_scope(scope)
           |> preload([_attachment, _note, file], storage_file: file)
           |> Repo.one() do
      {:ok, attachment}
    else
      nil -> {:error, :not_found}
      {:error, :invalid_note_id} -> {:error, :not_found}
      {:error, message} -> {:error, {:invalid_path, message}}
    end
  end

  defp attachment_query do
    from(attachment in Attachment,
      join: note in Note,
      on: note.id == attachment.note_id,
      join: file in StorageFile,
      on: file.id == attachment.storage_file_id,
      where: file.status == "active"
    )
  end

  defp active_scope(query), do: where(query, [_attachment, note, _file], is_nil(note.deleted_at))

  defp note_scope(query, :active), do: active_scope(query)

  defp note_scope(query, :deleted),
    do: where(query, [_attachment, note, _file], not is_nil(note.deleted_at))

  defp read_storage_file(%StorageFile{size: 0}), do: {:ok, ""}

  defp read_storage_file(%StorageFile{size: size} = file)
       when is_integer(size) and size > 0 do
    case Storage.read_range(file, 0, size - 1) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp read_storage_file(%StorageFile{}), do: {:error, {:storage, :invalid_size}}

  defp cast_note_id(note_id) do
    case Ecto.UUID.cast(note_id) do
      {:ok, note_id} -> {:ok, note_id}
      :error -> {:error, :invalid_note_id}
    end
  end

  defp validate_attachment_id(id) when is_binary(id) do
    if String.valid?(id) and String.trim(id) != "" and
         :binary.match(id, <<0>>) == :nomatch do
      :ok
    else
      {:error, :invalid_attachment_id}
    end
  end

  defp validate_attachment_id(_id), do: {:error, :invalid_attachment_id}

  defp validate_text(bytes) do
    if String.valid?(bytes) and :binary.match(bytes, <<0>>) == :nomatch do
      :ok
    else
      {:error, :invalid_text}
    end
  end

  defp attachment_error(id, code, details \\ %{}) do
    {:error, {:attachment, Map.merge(%{code: code, id: id}, details)}}
  end
end
