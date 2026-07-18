defmodule GSMLG.AdminWeb.GaoNoteLive.Index do
  use GSMLG.AdminWeb, :user_live_view

  alias GSMLG.AdminWeb.{GaoNoteAttachmentTemp, GaoNoteMarkdown}
  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note, Presenter}
  alias GSMLG.Storage.ContentType
  alias Phoenix.LiveView.AsyncResult

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: GaoNoteAttachmentTemp.sweep_stale()

    {:ok,
     socket
     |> assign(
       active_menu: "gao_note_list",
       notes: AsyncResult.loading(),
       filters: %{},
       label_filter_key: "",
       label_filter_operator: "=",
       label_filter_value: "",
       selected_labels: [],
       label_options: AsyncResult.loading(),
       label_key_input: "",
       label_value_input: "",
       attachment_temp_dir: GaoNoteAttachmentTemp.new_editor_dir(),
       attachment_monitor_started: false
     )
     |> allow_upload(:attachment,
       accept: :any,
       max_entries: 1,
       auto_upload: true,
       progress: &handle_attachment_upload_progress/3
     )
     |> assign_attachment_editor([])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :index, params) do
    filters = filter_params(params)

    socket
    |> assign(:page_title, "GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:filters, filters)
    |> assign_attachment_editor([])
    |> assign_notes_async(filter_opts(filters))
  end

  defp apply_action(socket, :new, _params) do
    changeset = GaoNote.change_note(%Note{})

    socket
    |> assign(:page_title, "New GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, %Note{})
    |> assign(:form, to_form(changeset, as: :gao_note))
    |> assign_label_state([])
    |> assign_attachment_editor([])
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    note = GaoNote.get_note!(id)
    selected_labels = Enum.map(note.labels, &label_input_value/1)

    socket
    |> assign(:page_title, "Edit GaoNote")
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, note)
    |> assign(:form, to_form(GaoNote.change_note(note), as: :gao_note))
    |> assign_label_state(selected_labels)
    |> assign_attachment_editor(note.attachments)
  end

  defp apply_action(socket, :show, %{"id" => id}) do
    note = GaoNote.get_note!(id)

    socket
    |> assign(:page_title, note.title)
    |> assign(:active_menu, "gao_note_list")
    |> assign(:note, note)
    |> assign_attachment_editor([])
  end

  @impl true
  def handle_event("search_form_changed", params, socket) do
    filters = filter_params(Map.get(params, "filters", %{}))
    label_filter = Map.get(params, "label_filter", %{})

    {:noreply,
     assign(socket,
       filters: filters,
       label_filter_key: Map.get(label_filter, "key", ""),
       label_filter_operator: normalize_filter_operator(Map.get(label_filter, "operator")),
       label_filter_value: Map.get(label_filter, "value", "")
     )}
  end

  def handle_event("search", %{"filters" => params}, socket) do
    filters = filter_params(params)
    {:noreply, push_patch(socket, to: note_filter_path(filters))}
  end

  def handle_event("add_search_filter", _params, socket) do
    key = String.trim(socket.assigns.label_filter_key)
    value = String.trim(socket.assigns.label_filter_value)

    if blank?(key) do
      {:noreply, socket}
    else
      label_filter = if blank?(value), do: key, else: "#{key}=#{value}"

      filters =
        Map.update!(socket.assigns.filters, "labels", fn labels ->
          normalize_label_filters(labels ++ [label_filter])
        end)

      {:noreply,
       socket
       |> assign(
         filters: filters,
         label_filter_key: "",
         label_filter_operator: "=",
         label_filter_value: ""
       )
       |> push_patch(to: note_filter_path(filters))}
    end
  end

  def handle_event("remove_search_filter", %{"filter" => label_filter}, socket) do
    filters =
      Map.update!(socket.assigns.filters, "labels", fn labels ->
        Enum.reject(labels, &(&1 == label_filter))
      end)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> push_patch(to: note_filter_path(filters))}
  end

  def handle_event("clear_search_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(
       filters: %{"search" => "", "labels" => []},
       label_filter_key: "",
       label_filter_operator: "=",
       label_filter_value: ""
     )
     |> push_patch(to: ~p"/gao_notes/notes")}
  end

  def handle_event("validate", %{"gao_note" => params}, socket) do
    selected_labels = selected_labels_from_params(params, socket)

    changeset =
      socket.assigns.note
      |> GaoNote.change_note(params)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :gao_note))
     |> assign_label_state(selected_labels)}
  end

  def handle_event("save", %{"gao_note" => params}, socket) do
    save_note(socket, socket.assigns.live_action, params)
  end

  def handle_event("open_attachment_modal", %{"operation" => "new"}, socket) do
    {:noreply,
     socket
     |> cancel_attachment_uploads()
     |> assign(:attachment_modal, %{
       open: true,
       operation: :new,
       draft_ref: nil,
       immutable_id: false,
       mime: nil,
       id_touched: false,
       path_touched: false,
       upload_entry_ref: nil,
       auto_id: nil,
       auto_path: nil
     })
     |> put_attachment_fields(new_attachment_fields())
     |> assign(:attachment_errors, %{})
     |> assign(:attachment_save_error, nil)}
  end

  def handle_event(
        "open_attachment_modal",
        %{"operation" => "edit_text", "ref" => ref},
        socket
      ) do
    case Map.get(socket.assigns.attachment_drafts, ref) do
      nil ->
        {:noreply,
         assign(socket, :attachment_save_error, "That attachment draft is no longer available.")}

      draft ->
        fields = %{
          "id" => draft.id,
          "path" => draft.path,
          "description" => draft.description,
          "source" => "text",
          "text" => ""
        }

        socket =
          socket
          |> cancel_attachment_uploads()
          |> assign(:attachment_modal, %{
            open: true,
            operation: :replace,
            draft_ref: ref,
            immutable_id: true,
            mime: draft.mime,
            id_touched: true,
            path_touched: true,
            upload_entry_ref: nil,
            auto_id: nil,
            auto_path: nil
          })
          |> put_attachment_fields(fields)
          |> assign(:attachment_save_error, nil)

        case draft.content do
          text when is_binary(text) ->
            {:noreply,
             socket
             |> put_attachment_fields(Map.put(fields, "text", text))
             |> assign(:attachment_errors, %{})}

          nil ->
            case socket.assigns.note do
              %Note{id: note_id} when is_binary(note_id) ->
                case GaoNote.read_attachment_text(note_id, draft.id) do
                  {:ok, text} ->
                    {:noreply,
                     socket
                     |> put_attachment_fields(Map.put(fields, "text", text))
                     |> assign(:attachment_errors, %{})}

                  {:error, reason} ->
                    {:noreply,
                     assign(socket, :attachment_errors, %{
                       "base" => [attachment_text_read_error(reason)]
                     })}
                end

              _note ->
                {:noreply,
                 assign(socket, :attachment_errors, %{
                   "base" => ["Save the note before editing persisted attachment text."]
                 })}
            end
        end
    end
  end

  def handle_event(
        "open_attachment_modal",
        %{"operation" => operation, "ref" => ref},
        socket
      )
      when operation in ["edit", "replace"] do
    case Map.get(socket.assigns.attachment_drafts, ref) do
      nil ->
        {:noreply,
         assign(socket, :attachment_save_error, "That attachment draft is no longer available.")}

      draft ->
        operation = if operation == "replace", do: :replace, else: :edit

        fields = %{
          "id" => draft.id,
          "path" => draft.path,
          "description" => draft.description,
          "source" => "file",
          "text" => ""
        }

        {:noreply,
         socket
         |> cancel_attachment_uploads()
         |> assign(:attachment_modal, %{
           open: true,
           operation: operation,
           draft_ref: ref,
           immutable_id: is_binary(draft.persisted_path),
           mime: draft.mime,
           id_touched: true,
           path_touched: true,
           upload_entry_ref: nil,
           auto_id: nil,
           auto_path: nil
         })
         |> put_attachment_fields(fields)
         |> assign(:attachment_errors, %{})
         |> assign(:attachment_save_error, nil)}
    end
  end

  def handle_event(
        "attachment_modal_changed",
        %{"attachment" => params} = event_params,
        socket
      ) do
    fields = merge_attachment_fields(socket.assigns.attachment_fields, params)

    socket =
      socket
      |> mark_attachment_fields_touched(Map.get(event_params, "_target", []))
      |> then(fn socket ->
        if fields["source"] == "text", do: cancel_attachment_uploads(socket), else: socket
      end)
      |> put_attachment_fields(fields)
      |> maybe_apply_upload_defaults()

    {:noreply, socket}
  end

  def handle_event("attachment_modal_changed", _params, socket) do
    {:noreply, maybe_apply_upload_defaults(socket)}
  end

  def handle_event("stage_attachment", %{"attachment" => params}, socket) do
    fields = merge_attachment_fields(socket.assigns.attachment_fields, params)
    stage_attachment(socket, fields, :selected)
  end

  def handle_event("stage_empty_attachment", _params, socket) do
    stage_attachment(socket, socket.assigns.attachment_fields, :empty)
  end

  defp handle_attachment_upload_progress(:attachment, _entry, socket) do
    {:noreply, maybe_apply_upload_defaults(socket)}
  end

  def handle_event("cancel_attachment_upload", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:attachment, ref)
     |> reset_canceled_upload_defaults(ref)}
  end

  def handle_event("cancel_attachment_modal", _params, socket) do
    {:noreply, reset_attachment_modal(socket)}
  end

  def handle_event("remove_attachment", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> remove_attachment_draft(ref)
     |> assign(:attachment_save_error, nil)}
  end

  def handle_event("cancel_note", _params, socket) do
    {:noreply,
     socket
     |> assign_attachment_editor([])
     |> push_patch(to: ~p"/gao_notes/notes")}
  end

  def handle_event("set_labels", %{"labels" => label_names}, socket) do
    {:noreply, assign_label_state(socket, label_names)}
  end

  def handle_event("label_input_changed", params, socket) do
    {:noreply,
     socket
     |> assign(
       :label_key_input,
       Map.get(params, "label_key_input", socket.assigns.label_key_input)
     )
     |> assign(
       :label_value_input,
       Map.get(params, "label_value_input", socket.assigns.label_value_input)
     )}
  end

  def handle_event("add_label_option", %{"key" => key} = params, socket) do
    if blank?(key) do
      {:noreply, socket}
    else
      value = Map.get(params, "value", "")
      label = "#{String.trim(key)}=#{String.trim(value)}"
      selected_labels = normalize_label_names(socket.assigns.selected_labels ++ [label])

      {:noreply,
       socket
       |> assign(:label_key_input, "")
       |> assign(:label_value_input, "")
       |> assign_label_state(selected_labels)}
    end
  end

  def handle_event("add_label_option", _params, socket), do: {:noreply, socket}

  def handle_event("delete", %{"id" => id}, socket) do
    note = GaoNote.get_note!(id)

    case GaoNote.delete_note(note, current_actor(socket)) do
      {:ok, _note} ->
        {:noreply,
         socket
         |> put_flash(:info, "GaoNote deleted")
         |> push_patch(to: ~p"/gao_notes/notes")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Delete failed: #{inspect(reason)}")}
    end
  end

  defp save_note(socket, action, params) when action in [:new, :edit] do
    case attachment_payloads(socket) do
      {:ok, attachments} ->
        params =
          params
          |> put_selected_labels(socket)
          |> Map.put("attachments", attachments)

        result =
          case action do
            :new -> GaoNote.create_note(params, current_actor(socket))
            :edit -> GaoNote.update_note(socket.assigns.note, params, current_actor(socket))
          end

        handle_note_save_result(socket, result, action)

      {:error, ref, reason} ->
        {:noreply,
         socket
         |> remove_attachment_draft(ref)
         |> assign(
           :attachment_save_error,
           "A staged file is no longer readable (#{inspect(reason)}). Restage it before saving."
         )}
    end
  end

  defp handle_note_save_result(socket, {:ok, note}, action) do
    message = if action == :new, do: "GaoNote created", else: "GaoNote updated"

    {:noreply,
     socket
     |> put_flash(:info, message)
     |> assign_attachment_editor([])
     |> push_patch(to: ~p"/gao_notes/notes/#{note.id}/show")}
  end

  defp handle_note_save_result(socket, {:error, %Ecto.Changeset{} = changeset}, _action) do
    {:noreply,
     socket
     |> assign(:form, to_form(changeset, as: :gao_note))
     |> assign(:attachment_save_error, nil)}
  end

  defp handle_note_save_result(socket, {:error, reason}, _action) do
    {:noreply, assign(socket, :attachment_save_error, attachment_error_text(reason))}
  end

  defp assign_attachment_editor(socket, attachments) do
    socket = cleanup_all_draft_temp_files(socket)

    {drafts, order} =
      attachments
      |> loaded_list()
      |> Enum.sort_by(&{&1.path, &1.id})
      |> Enum.reduce({%{}, []}, fn %Attachment{} = attachment, {drafts, order} ->
        ref = Ecto.UUID.generate()

        draft = %{
          ref: ref,
          id: attachment.id,
          path: attachment.path,
          persisted_path: attachment.path,
          mime: attachment.mime,
          description: attachment.description || "",
          state: :existing,
          content: nil,
          temp_path: nil,
          size: nil,
          source: :existing
        }

        {Map.put(drafts, ref, draft), order ++ [ref]}
      end)

    socket
    |> cancel_attachment_uploads()
    |> assign(
      attachment_drafts: drafts,
      attachment_order: order,
      attachment_modal: %{
        open: false,
        operation: :new,
        draft_ref: nil,
        immutable_id: false,
        mime: nil,
        id_touched: false,
        path_touched: false,
        upload_entry_ref: nil,
        auto_id: nil,
        auto_path: nil
      },
      attachment_errors: %{},
      attachment_save_error: nil
    )
    |> put_attachment_fields(new_attachment_fields())
  end

  defp new_attachment_fields do
    %{
      "id" => "",
      "path" => "./data.txt",
      "description" => "",
      "source" => "file",
      "text" => ""
    }
  end

  defp put_attachment_fields(socket, fields) do
    assign(socket,
      attachment_fields: fields,
      attachment_form: to_form(fields, as: :attachment)
    )
  end

  defp merge_attachment_fields(current, params) do
    Enum.reduce(~w(id path description source text), current, fn key, fields ->
      case Map.fetch(params, key) do
        {:ok, value} when is_binary(value) -> Map.put(fields, key, value)
        _other -> fields
      end
    end)
  end

  defp mark_attachment_fields_touched(socket, ["attachment", field])
       when field in ["id", "path"] do
    key = if field == "id", do: :id_touched, else: :path_touched
    assign(socket, :attachment_modal, Map.put(socket.assigns.attachment_modal, key, true))
  end

  defp mark_attachment_fields_touched(socket, _target), do: socket

  defp maybe_apply_upload_defaults(socket) do
    modal = socket.assigns.attachment_modal

    case socket.assigns.uploads.attachment.entries do
      [entry | _entries]
      when modal.operation == :new and modal.upload_entry_ref != entry.ref ->
        {fields, modal} =
          socket.assigns.attachment_fields
          |> reset_auto_populated_fields(modal)
          |> apply_upload_defaults(entry, modal)

        socket
        |> assign(:attachment_modal, modal)
        |> put_attachment_fields(fields)

      _entries ->
        socket
    end
  end

  defp apply_upload_defaults(fields, entry, modal) do
    {fields, auto_id} =
      if modal.id_touched do
        {fields, nil}
      else
        generated_id = "attachment-#{Ecto.UUID.generate()}"
        {Map.put(fields, "id", generated_id), generated_id}
      end

    {fields, auto_path} =
      if modal.path_touched do
        {fields, nil}
      else
        case canonical_client_attachment_path(entry.client_name) do
          {:ok, path} -> {Map.put(fields, "path", path), path}
          {:error, _reason} -> {fields, nil}
        end
      end

    modal =
      Map.merge(modal, %{
        upload_entry_ref: entry.ref,
        auto_id: auto_id,
        auto_path: auto_path
      })

    {fields, modal}
  end

  defp canonical_client_attachment_path(client_name) do
    client_name =
      client_name
      |> String.replace("\\", "/")
      |> Path.basename()

    Attachment.normalize_path("./#{client_name}")
  end

  defp reset_canceled_upload_defaults(socket, ref) do
    modal = socket.assigns.attachment_modal

    if modal.upload_entry_ref == ref do
      fields = reset_auto_populated_fields(socket.assigns.attachment_fields, modal)

      socket
      |> assign(
        :attachment_modal,
        Map.merge(modal, %{upload_entry_ref: nil, auto_id: nil, auto_path: nil})
      )
      |> put_attachment_fields(fields)
    else
      socket
    end
  end

  defp reset_auto_populated_fields(fields, modal) do
    fields
    |> maybe_reset_auto_field("id", modal.auto_id, modal.id_touched, "")
    |> maybe_reset_auto_field("path", modal.auto_path, modal.path_touched, "./data.txt")
  end

  defp maybe_reset_auto_field(fields, field, auto_value, false, reset_value)
       when is_binary(auto_value) do
    if fields[field] == auto_value, do: Map.put(fields, field, reset_value), else: fields
  end

  defp maybe_reset_auto_field(fields, _field, _auto_value, _touched, _reset_value), do: fields

  defp validate_attachment_metadata(fields, socket) do
    modal = socket.assigns.attachment_modal
    draft = Map.get(socket.assigns.attachment_drafts, modal.draft_ref)

    errors =
      if modal.operation != :new and is_nil(draft) do
        put_attachment_error(%{}, "base", "That attachment draft is no longer available.")
      else
        %{}
      end

    id =
      if modal.immutable_id and draft do
        draft.id
      else
        fields |> Map.get("id", "") |> String.trim()
      end

    description = Map.get(fields, "description", "")

    errors =
      errors
      |> validate_attachment_text("id", id, required: true)
      |> validate_attachment_text("description", description)

    {path, errors} =
      case Attachment.normalize_path(Map.get(fields, "path", "")) do
        {:ok, path} -> {path, errors}
        {:error, message} -> {nil, put_attachment_error(errors, "path", message)}
      end

    other_drafts =
      socket.assigns.attachment_order
      |> Enum.reject(&(&1 == modal.draft_ref))
      |> Enum.map(&Map.fetch!(socket.assigns.attachment_drafts, &1))

    errors =
      if Enum.any?(other_drafts, &(&1.id == id)) do
        put_attachment_error(errors, "id", "must be unique within this note")
      else
        errors
      end

    errors =
      if is_binary(path) and Enum.any?(other_drafts, &(&1.path == path)) do
        put_attachment_error(errors, "path", "must be unique within this note")
      else
        errors
      end

    if map_size(errors) == 0 do
      {:ok, %{id: id, path: path, description: description}}
    else
      {:error, errors}
    end
  end

  defp validate_attachment_text(errors, field, value, opts \\ []) do
    cond do
      not is_binary(value) ->
        put_attachment_error(errors, field, "must be a string")

      not String.valid?(value) ->
        put_attachment_error(errors, field, "must be valid UTF-8")

      :binary.match(value, <<0>>) != :nomatch ->
        put_attachment_error(errors, field, "must not contain NUL bytes")

      Keyword.get(opts, :required, false) and String.trim(value) == "" ->
        put_attachment_error(errors, field, "can't be blank")

      true ->
        errors
    end
  end

  defp put_attachment_error(errors, field, message) do
    Map.update(errors, field, [message], &(&1 ++ [message]))
  end

  defp stage_attachment(socket, fields, requested_source) do
    socket =
      socket
      |> ensure_attachment_temp_monitor()
      |> put_attachment_fields(fields)

    case validate_attachment_metadata(fields, socket) do
      {:ok, metadata} ->
        fields =
          fields
          |> Map.put("id", metadata.id)
          |> Map.put("path", metadata.path)
          |> Map.put("description", metadata.description)

        case modal_attachment_content(socket, fields, requested_source) do
          {:ok, :retain} ->
            finish_staging_attachment(socket, fields, metadata, :retain)

          {:ok, staged_content} ->
            case detect_staged_content(staged_content, metadata.path) do
              {:ok, mime} ->
                finish_staging_attachment(
                  socket,
                  fields,
                  Map.put(metadata, :mime, mime),
                  staged_content
                )

              {:error, reason} ->
                cleanup_staged_content(socket, staged_content)

                {:noreply,
                 socket
                 |> put_attachment_fields(fields)
                 |> assign(:attachment_errors, %{
                   "file" => ["could not read the staged file: #{inspect(reason)}"]
                 })}
            end

          {:error, errors} ->
            {:noreply,
             socket
             |> put_attachment_fields(fields)
             |> assign(:attachment_errors, errors)}
        end

      {:error, errors} ->
        {:noreply, assign(socket, :attachment_errors, errors)}
    end
  end

  defp finish_staging_attachment(socket, fields, metadata, staged_content) do
    {:noreply,
     socket
     |> put_attachment_fields(fields)
     |> stage_attachment_draft(metadata, staged_content)
     |> reset_attachment_modal(cancel_uploads: false)
     |> assign(:attachment_save_error, nil)}
  end

  defp modal_attachment_content(socket, _fields, _requested_source)
       when socket.assigns.attachment_modal.operation == :edit,
       do: {:ok, :retain}

  defp modal_attachment_content(socket, _fields, :empty),
    do: create_empty_staged_file(socket)

  defp modal_attachment_content(socket, fields, :selected) do
    case fields["source"] do
      "text" ->
        case validate_attachment_text_content(fields["text"]) do
          {:ok, text} -> {:ok, {:text, text}}
          {:error, errors} -> {:error, errors}
        end

      "file" ->
        consume_attachment_upload(socket)

      _source ->
        {:error, %{"source" => ["select a file or UTF-8 text source"]}}
    end
  end

  defp validate_attachment_text_content(text) when is_binary(text) do
    cond do
      not String.valid?(text) ->
        {:error, %{"text" => ["must be valid UTF-8"]}}

      :binary.match(text, <<0>>) != :nomatch ->
        {:error, %{"text" => ["must not contain NUL bytes"]}}

      true ->
        {:ok, text}
    end
  end

  defp validate_attachment_text_content(_text),
    do: {:error, %{"text" => ["must be valid UTF-8 text"]}}

  defp consume_attachment_upload(socket) do
    {completed, in_progress} = uploaded_entries(socket, :attachment)

    cond do
      in_progress != [] ->
        {:error, %{"file" => ["wait for the file upload to complete"]}}

      completed == [] ->
        {:error, %{"file" => ["select a file"]}}

      true ->
        editor_dir = socket.assigns.attachment_temp_dir

        results =
          consume_uploaded_entries(socket, :attachment, fn %{path: path}, entry ->
            {:ok, copy_uploaded_file(editor_dir, path, entry.client_size)}
          end)

        case results do
          [{:ok, temp_path, size}] ->
            {:ok, {:file, temp_path, size}}

          [{:error, reason}] ->
            {:error, %{"file" => ["could not stage the uploaded file: #{inspect(reason)}"]}}

          _results ->
            {:error, %{"file" => ["select exactly one completed file"]}}
        end
    end
  end

  defp copy_uploaded_file(editor_dir, source_path, client_size) do
    case GaoNoteAttachmentTemp.copy_upload(editor_dir, source_path) do
      {:ok, temp_path, size} -> {:ok, temp_path, size}
      {:error, reason} -> {:error, {reason, client_size}}
    end
  end

  defp create_empty_staged_file(socket) do
    case GaoNoteAttachmentTemp.create_empty(socket.assigns.attachment_temp_dir) do
      {:ok, temp_path, 0} ->
        {:ok, {:file, temp_path, 0}}

      {:error, reason} ->
        {:error, %{"file" => ["could not stage an empty file: #{inspect(reason)}"]}}
    end
  end

  defp detect_staged_content({:text, bytes}, canonical_path) do
    ContentType.detect(bytes, canonical_path)
  end

  defp detect_staged_content({:file, temp_path, _size}, canonical_path) do
    with {:ok, bytes} <- File.read(temp_path),
         {:ok, mime} <- ContentType.detect(bytes, canonical_path) do
      {:ok, mime}
    end
  end

  defp stage_attachment_draft(socket, metadata, :retain) do
    ref = socket.assigns.attachment_modal.draft_ref
    draft = Map.fetch!(socket.assigns.attachment_drafts, ref)

    draft = %{
      draft
      | id: metadata.id,
        path: metadata.path,
        description: metadata.description
    }

    assign(socket, :attachment_drafts, Map.put(socket.assigns.attachment_drafts, ref, draft))
  end

  defp stage_attachment_draft(socket, metadata, staged_content) do
    {content, temp_path, size, source} =
      case staged_content do
        {:text, bytes} -> {bytes, nil, byte_size(bytes), :text}
        {:file, path, size} -> {nil, path, size, :file}
      end

    case socket.assigns.attachment_modal.operation do
      :new ->
        ref = Ecto.UUID.generate()

        draft = %{
          ref: ref,
          id: metadata.id,
          path: metadata.path,
          persisted_path: nil,
          mime: metadata.mime,
          description: metadata.description,
          state: :new,
          content: content,
          temp_path: temp_path,
          size: size,
          source: source
        }

        assign(socket,
          attachment_drafts: Map.put(socket.assigns.attachment_drafts, ref, draft),
          attachment_order: socket.assigns.attachment_order ++ [ref]
        )

      :replace ->
        ref = socket.assigns.attachment_modal.draft_ref
        draft = Map.fetch!(socket.assigns.attachment_drafts, ref)
        state = if draft.state == :new, do: :new, else: :replacement
        GaoNoteAttachmentTemp.cleanup_file(socket.assigns.attachment_temp_dir, draft.temp_path)

        draft = %{
          draft
          | id: metadata.id,
            path: metadata.path,
            mime: metadata.mime,
            description: metadata.description,
            state: state,
            content: content,
            temp_path: temp_path,
            size: size,
            source: source
        }

        assign(
          socket,
          :attachment_drafts,
          Map.put(socket.assigns.attachment_drafts, ref, draft)
        )
    end
  end

  defp reset_attachment_modal(socket, opts \\ []) do
    socket =
      if Keyword.get(opts, :cancel_uploads, true) do
        cancel_attachment_uploads(socket)
      else
        socket
      end

    socket
    |> assign(
      attachment_modal: %{
        open: false,
        operation: :new,
        draft_ref: nil,
        immutable_id: false,
        mime: nil,
        id_touched: false,
        path_touched: false,
        upload_entry_ref: nil,
        auto_id: nil,
        auto_path: nil
      },
      attachment_errors: %{}
    )
    |> put_attachment_fields(new_attachment_fields())
  end

  defp cancel_attachment_uploads(socket) do
    case socket.assigns[:uploads] do
      %{attachment: upload} ->
        Enum.reduce(upload.entries, socket, fn entry, socket ->
          cancel_upload(socket, :attachment, entry.ref)
        end)

      _uploads ->
        socket
    end
  end

  defp attachment_payloads(socket) do
    Enum.reduce_while(socket.assigns.attachment_order, {:ok, []}, fn ref, {:ok, payloads} ->
      draft = Map.fetch!(socket.assigns.attachment_drafts, ref)

      payload = %{
        "id" => draft.id,
        "path" => draft.path,
        "mime" => draft.mime,
        "description" => draft.description
      }

      case draft_content_payload(socket, draft) do
        {:ok, content_source} ->
          {:cont, {:ok, [Map.merge(payload, content_source) | payloads]}}

        {:error, reason} ->
          {:halt, {:error, ref, reason}}
      end
    end)
    |> case do
      {:ok, payloads} -> {:ok, Enum.reverse(payloads)}
      error -> error
    end
  end

  defp draft_content_payload(
         socket,
         %{temp_path: temp_path, path: canonical_path, mime: mime}
       )
       when is_binary(temp_path) do
    if GaoNoteAttachmentTemp.regular_file?(socket.assigns.attachment_temp_dir, temp_path) do
      {:ok,
       %{
         "upload" => %Plug.Upload{
           path: temp_path,
           filename: Path.basename(canonical_path),
           content_type: mime
         }
       }}
    else
      {:error, :staged_file_missing}
    end
  end

  defp draft_content_payload(_socket, %{content: bytes}) when is_binary(bytes),
    do: {:ok, %{"content_base64" => Base.encode64(bytes)}}

  defp draft_content_payload(_socket, _draft), do: {:ok, %{}}

  defp attachment_cards(drafts, order, note) do
    Enum.map(order, fn ref ->
      draft = Map.fetch!(drafts, ref)

      %{
        ref: ref,
        id: draft.id,
        path: draft.path,
        mime: draft.mime,
        description: draft.description,
        state: draft.state,
        state_label: attachment_state_label(draft.state),
        state_variant: attachment_state_variant(draft.state),
        raw_url: raw_attachment_url(note.id, draft.persisted_path),
        text_editable:
          editable_text_mime?(draft.mime) and
            (is_binary(draft.persisted_path) or is_binary(draft.content)),
        markdown: GaoNoteMarkdown.reference(draft)
      }
    end)
  end

  defp attachment_state_label(:existing), do: "Existing"
  defp attachment_state_label(:new), do: "New"
  defp attachment_state_label(:replacement), do: "Replacement"

  defp attachment_state_variant(:existing), do: "secondary"
  defp attachment_state_variant(:new), do: "info"
  defp attachment_state_variant(:replacement), do: "warning"

  defp raw_attachment_url(note_id, path), do: GaoNoteMarkdown.attachment_url(note_id, path)

  defp editable_text_mime?("text/" <> _subtype), do: true
  defp editable_text_mime?("application/json"), do: true
  defp editable_text_mime?("application/xml"), do: true
  defp editable_text_mime?(_mime), do: false

  defp rendered_note_content(%Note{} = note), do: GaoNoteMarkdown.render(note)

  defp show_attachment_cards(%Note{} = note) do
    note.attachments
    |> loaded_list()
    |> Enum.with_index()
    |> Enum.map(fn {attachment, index} ->
      %{
        ref: index,
        path: attachment.path,
        mime: attachment.mime,
        description: attachment.description || "",
        raw_url: raw_attachment_url(note.id, attachment.path)
      }
    end)
  end

  defp remove_attachment_draft(socket, ref) do
    case Map.get(socket.assigns.attachment_drafts, ref) do
      nil -> socket
      draft ->
        GaoNoteAttachmentTemp.cleanup_file(
          socket.assigns.attachment_temp_dir,
          draft.temp_path
        )
    end

    assign(socket,
      attachment_drafts: Map.delete(socket.assigns.attachment_drafts, ref),
      attachment_order: Enum.reject(socket.assigns.attachment_order, &(&1 == ref))
    )
  end

  defp cleanup_all_draft_temp_files(socket) do
    GaoNoteAttachmentTemp.cleanup_editor(socket.assigns.attachment_temp_dir)
    socket
  end

  defp ensure_attachment_temp_monitor(socket) do
    if socket.assigns.attachment_monitor_started do
      socket
    else
      case GaoNoteAttachmentTemp.monitor_owner(self(), socket.assigns.attachment_temp_dir) do
        {:ok, _pid} -> assign(socket, :attachment_monitor_started, true)
        {:error, _reason} -> socket
      end
    end
  end

  defp cleanup_staged_content(socket, {:file, temp_path, _size}) do
    GaoNoteAttachmentTemp.cleanup_file(socket.assigns.attachment_temp_dir, temp_path)
  end

  defp cleanup_staged_content(_socket, _staged_content), do: :ok

  defp attachment_text_read_error(reason) do
    detail = Presenter.error_text(reason)
    normalized = String.downcase(detail)

    cond do
      String.contains?(normalized, "not_found") or String.contains?(normalized, "not found") ->
        "Attachment text is no longer available. Reload the editor and try again."

      String.contains?(normalized, "utf") or String.contains?(normalized, "nul") or
          String.contains?(normalized, "invalid_text") ->
        "Attachment content is not valid UTF-8 text and cannot be edited here."

      true ->
        "Attachment text could not be loaded: #{detail}"
    end
  end

  defp attachment_error_text({:attachments, %{code: :duplicate_id, id: id}}),
    do: "Attachment ID #{id} appears more than once."

  defp attachment_error_text({:attachments, %{code: :duplicate_path, path: path}}),
    do: "Attachment path #{path} appears more than once."

  defp attachment_error_text({:attachments, %{code: :stale}}),
    do: "Attachments changed elsewhere. Reload the editor and reapply your changes."

  defp attachment_error_text({:attachment, %{code: :owned_by_another_note, id: id}}),
    do: "Attachment ID #{id} already belongs to another note. Choose a globally unique ID."

  defp attachment_error_text(
         {:attachment, %{code: :mime_mismatch, id: id, detected: detected}}
       ),
       do: "Attachment #{id} was detected as #{detected}. Restage its content."

  defp attachment_error_text({:attachment, %{code: :content_required, id: id}}),
    do: "Attachment #{id} needs file or text content."

  defp attachment_error_text(
         {:attachment_input, %{index: index, changeset: %Ecto.Changeset{} = changeset}}
       ),
       do: "Attachment #{index + 1} is invalid: #{Presenter.error_text(changeset)}"

  defp attachment_error_text({:attachment, %{code: code, id: id, reason: reason}})
       when code in [:content_read_failed, :staging_failed],
       do: "Attachment #{id} could not be staged: #{inspect(reason)}"

  defp attachment_error_text(reason), do: "Attachments could not be saved: #{Presenter.error_text(reason)}"

  defp attachment_errors_for(errors, field), do: Map.get(errors, field, [])

  defp upload_error_text(:too_large), do: "File exceeds the LiveView upload limit."
  defp upload_error_text(:too_many_files), do: "Select one file only."
  defp upload_error_text(:not_accepted), do: "That file type is not accepted."
  defp upload_error_text(error), do: "Upload failed: #{inspect(error)}"

  defp attachment_modal_title(%{operation: :new}), do: "Add attachment"
  defp attachment_modal_title(%{operation: :edit}), do: "Edit attachment metadata"
  defp attachment_modal_title(%{operation: :replace}), do: "Replace attachment content"

  defp attachment_modal_submit_label(%{operation: :new}), do: "Add attachment"
  defp attachment_modal_submit_label(%{operation: :edit}), do: "Stage metadata"
  defp attachment_modal_submit_label(%{operation: :replace}), do: "Stage replacement"

  defp attachment_editor(assigns) do
    ~H"""
    <section
      id="gao-note-attachments"
      class="grid gap-4 rounded-2xl border border-outline-variant bg-surface-container-low p-4 text-on-surface sm:p-5"
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div class="grid gap-1">
          <div class="flex items-center gap-2">
            <.dm_mdi name="paperclip" class="h-5 w-5 text-secondary" />
            <h2 class="text-lg font-semibold">Attachments</h2>
            <.dm_badge variant="secondary" soft>{@attachments |> length()}</.dm_badge>
          </div>
          <p class="text-sm text-on-surface-variant">
            Files and UTF-8 text are staged here and persist only when you save the note.
          </p>
        </div>

        <.dm_btn
          :if={!@modal.open}
          id="gao-note-add-attachment"
          type="button"
          size="sm"
          variant="secondary"
          phx-click="open_attachment_modal"
          phx-value-operation="new"
        >
          <.dm_mdi name="plus" class="h-4 w-4" /> Add attachment
        </.dm_btn>
      </div>

      <section
        :if={@modal.open}
        id="gao-note-attachment-inline-form"
        class="grid gap-4 rounded-xl border border-secondary/40 bg-surface-container p-4"
      >
        <div class="grid gap-1">
          <h3 class="font-semibold">{attachment_modal_title(@modal)}</h3>
          <p class="text-sm text-on-surface-variant">
            Stage the attachment here, then save the note to persist it.
          </p>
        </div>

        <.dm_form
          id="gao-note-attachment-form"
          for={@form}
          phx-change="attachment_modal_changed"
          phx-submit="stage_attachment"
          class="grid gap-4"
        >
              <div
                :if={attachment_errors_for(@errors, "base") != []}
                class="rounded-xl bg-error-container p-3 text-sm text-on-error-container"
                role="alert"
              >
                <p :for={message <- attachment_errors_for(@errors, "base")}>{message}</p>
              </div>

              <div class="grid gap-4 sm:grid-cols-2">
                <.dm_input
                  field={@form[:id]}
                  label="Globally unique ID"
                  readonly={@modal.immutable_id}
                  errors={attachment_errors_for(@errors, "id")}
                />
                <.dm_input
                  field={@form[:path]}
                  label="Canonical path"
                  placeholder="./data.txt"
                  errors={attachment_errors_for(@errors, "path")}
                />
              </div>

              <.dm_input
                field={@form[:description]}
                label="Description"
                errors={attachment_errors_for(@errors, "description")}
              />

              <.dm_input
                id="gao-note-attachment-mime"
                name="attachment_detected_mime"
                label="Verified MIME"
                value={@modal.mime || "Detected from staged bytes"}
                readonly
              />

              <div :if={@modal.operation in [:new, :replace]} class="grid gap-4">
                <.dm_select
                  field={@form[:source]}
                  label="Source"
                  options={[{"file", "File"}, {"text", "UTF-8 text"}]}
                  errors={attachment_errors_for(@errors, "source")}
                />

                <div
                  :if={@form[:source].value == "file"}
                  class="grid gap-3 rounded-xl border border-dashed border-outline bg-surface-container p-4"
                  phx-drop-target={@upload.ref}
                >
                  <div class="flex items-center gap-2 text-sm text-on-surface-variant">
                    <.dm_mdi name="cloud-upload-outline" class="h-5 w-5" />
                    <span>Drop one file here or browse.</span>
                  </div>
                  <.live_file_input
                    upload={@upload}
                    class="file-input file-input-bordered w-full"
                  />
                  <div class="flex flex-wrap items-center justify-between gap-2">
                    <span class="text-xs text-on-surface-variant">
                      Need an intentionally empty file?
                    </span>
                    <.dm_btn
                      id="gao-note-stage-empty-attachment"
                      type="button"
                      size="sm"
                      variant="secondary"
                      phx-click="stage_empty_attachment"
                    >
                      Stage empty file
                    </.dm_btn>
                  </div>

                  <div
                    :for={entry <- @upload.entries}
                    class="grid gap-2 rounded-lg bg-surface-container-high p-3"
                  >
                    <div class="flex items-center gap-2 text-sm">
                      <span class="min-w-0 flex-1 truncate font-mono">{entry.client_name}</span>
                      <span class="text-xs tabular-nums text-on-surface-variant">
                        {entry.progress}%
                      </span>
                      <.dm_btn
                        type="button"
                        size="xs"
                        variant="ghost"
                        class="text-error"
                        phx-click="cancel_attachment_upload"
                        phx-value-ref={entry.ref}
                        aria-label={"Cancel upload #{entry.client_name}"}
                      >
                        <.dm_mdi name="close" class="h-4 w-4" />
                      </.dm_btn>
                    </div>
                    <progress
                      class="progress progress-secondary w-full"
                      value={entry.progress}
                      max="100"
                    >
                    </progress>
                    <.dm_error :for={error <- upload_errors(@upload, entry)}>
                      {upload_error_text(error)}
                    </.dm_error>
                  </div>

                  <.dm_error :for={message <- attachment_errors_for(@errors, "file")}>
                    {message}
                  </.dm_error>
                  <.dm_error :for={error <- upload_errors(@upload)}>
                    {upload_error_text(error)}
                  </.dm_error>
                </div>

                <.dm_textarea
                  :if={@form[:source].value == "text"}
                  field={@form[:text]}
                  label="UTF-8 text"
                  rows={9}
                  errors={attachment_errors_for(@errors, "text")}
                />
              </div>

              <:actions>
                <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
                  <.dm_btn
                    type="button"
                    variant="ghost"
                    phx-click="cancel_attachment_modal"
                  >
                    Cancel
                  </.dm_btn>
                  <button type="submit" class="btn btn-secondary">
                    {attachment_modal_submit_label(@modal)}
                  </button>
                </div>
              </:actions>
        </.dm_form>
      </section>

      <div
        :if={@save_error}
        id="gao-note-attachment-save-error"
        class="rounded-xl bg-error-container p-3 text-sm text-on-error-container"
        role="alert"
      >
        {@save_error}
      </div>

      <div
        :if={@attachments == []}
        id="gao-note-attachments-empty"
        class="rounded-xl border border-outline-variant bg-surface-container p-6 text-center text-sm text-on-surface-variant"
      >
        No attachments staged.
      </div>

      <div
        :if={@attachments != []}
        id="gao-note-attachments-grid"
        class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3"
      >
        <.dm_card
          :for={attachment <- @attachments}
          id={"gao-note-attachment-#{attachment.ref}"}
          data-attachment-id={attachment.id}
          variant="bordered"
          class="min-w-0 bg-surface-container text-on-surface"
          body_class="grid h-full gap-3"
        >
          <div class="flex items-start justify-between gap-2">
            <div class="min-w-0">
              <div class="truncate font-mono text-sm font-semibold">{attachment.id}</div>
              <div class="truncate font-mono text-xs text-on-surface-variant">
                {attachment.path}
              </div>
            </div>
            <.dm_badge variant={attachment.state_variant} soft>
              {attachment.state_label}
            </.dm_badge>
          </div>

          <dl class="grid gap-2 text-sm">
            <div>
              <dt class="text-xs font-medium uppercase tracking-wide text-on-surface-variant">
                Verified MIME
              </dt>
              <dd class="break-all font-mono text-xs">{attachment.mime}</dd>
            </div>
            <div>
              <dt class="text-xs font-medium uppercase tracking-wide text-on-surface-variant">
                Description
              </dt>
              <dd class="break-words">
                {if attachment.description == "", do: "No description", else: attachment.description}
              </dd>
            </div>
          </dl>

          <div class="mt-auto flex flex-wrap gap-1 border-t border-outline-variant pt-3">
            <a
              :if={attachment.raw_url}
              href={attachment.raw_url}
              target="_blank"
              rel="noopener"
              class="btn btn-ghost btn-sm"
            >
              <.dm_mdi name="open-in-new" class="h-4 w-4" /> Open
            </a>
            <button
              id={"gao-note-copy-attachment-#{attachment.ref}"}
              type="button"
              class="btn btn-ghost btn-sm"
              phx-hook="Clipboard"
              data-clipboard-text={attachment.markdown}
              title={attachment.markdown}
            >
              <.dm_mdi name="content-copy" class="h-4 w-4" />
              <span data-clipboard-feedback>Copy Markdown</span>
            </button>
            <.dm_btn
              :if={attachment.text_editable}
              type="button"
              size="sm"
              variant="ghost"
              phx-click="open_attachment_modal"
              phx-value-operation="edit_text"
              phx-value-ref={attachment.ref}
              onclick="document.getElementById('gao-note-attachment-modal').show()"
            >
              Edit text
            </.dm_btn>
            <.dm_btn
              type="button"
              size="sm"
              variant="ghost"
              phx-click="open_attachment_modal"
              phx-value-operation="edit"
              phx-value-ref={attachment.ref}
              onclick="document.getElementById('gao-note-attachment-modal').show()"
            >
              Edit metadata
            </.dm_btn>
            <.dm_btn
              type="button"
              size="sm"
              variant="ghost"
              phx-click="open_attachment_modal"
              phx-value-operation="replace"
              phx-value-ref={attachment.ref}
              onclick="document.getElementById('gao-note-attachment-modal').show()"
            >
              Replace
            </.dm_btn>
            <.dm_btn
              type="button"
              size="sm"
              variant="ghost"
              class="text-error"
              phx-click="remove_attachment"
              phx-value-ref={attachment.ref}
            >
              Remove
            </.dm_btn>
          </div>
        </.dm_card>
      </div>
    </section>
    """
  end

  defp filter_params(params) do
    %{
      "search" => Map.get(params, "search", ""),
      "labels" =>
        params
        |> Map.get("labels", Map.get(params, "label", []))
        |> normalize_label_filters()
    }
  end

  defp filter_opts(filters) do
    [
      search: blank_to_nil(filters["search"]),
      label: filters["labels"],
      limit: 100
    ]
  end

  defp note_filter_path(filters) do
    query =
      []
      |> maybe_put_query(:search, blank_to_nil(filters["search"]))
      |> maybe_put_query(:labels, filters["labels"])

    ~p"/gao_notes/notes?#{query}"
  end

  defp maybe_put_query(query, _key, value) when value in [nil, "", []], do: query
  defp maybe_put_query(query, key, value), do: Keyword.put(query, key, value)

  defp normalize_label_filters(filters) do
    filters
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&String.downcase/1)
  end

  defp normalize_filter_operator("="), do: "="
  defp normalize_filter_operator(_operator), do: "="

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp label_input_value(%Label{
         label_setting: %LabelSetting{name: name},
         value: value
       }),
       do: "#{name}=#{value || ""}"

  defp assign_notes_async(socket, opts) do
    assign_async(
      socket,
      :notes,
      fn -> {:ok, %{notes: GaoNote.list_notes(opts)}} end,
      reset: true
    )
  end

  defp selected_labels_from_params(params, socket) do
    params
    |> Map.get("labels", socket.assigns.selected_labels)
    |> normalize_label_names()
  end

  defp put_selected_labels(params, socket) do
    Map.put(params, "labels", selected_labels_from_params(params, socket))
  end

  defp assign_label_state(socket, label_names) do
    selected_labels = normalize_label_names(label_names)

    socket
    |> assign(:selected_labels, selected_labels)
    |> assign_label_options_async(selected_labels)
  end

  defp assign_label_options_async(socket, selected_labels) do
    assign_async(
      socket,
      :label_options,
      fn -> {:ok, %{label_options: label_options(selected_labels)}} end,
      reset: true
    )
  end

  defp label_options(selected_labels) do
    existing_names =
      [limit: 200]
      |> GaoNote.list_label_settings()
      |> Enum.map(& &1.name)

    existing_names
    |> Enum.concat(selected_labels)
    |> normalize_label_names()
    |> Enum.map(&%{value: &1, label: &1})
  end

  defp normalize_label_names(label_names) do
    label_names
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.map(&LabelSetting.normalize_display_name/1)
    |> Enum.reject(&blank?/1)
    |> Enum.uniq_by(&LabelSetting.normalized_key/1)
  end

  defp selected_label_options(selected_labels) do
    selected_labels
    |> normalize_label_names()
    |> Enum.map(&%{value: &1, label: &1})
  end

  defp async_value(%AsyncResult{ok?: true, result: result}, _fallback), do: result
  defp async_value(_result, fallback), do: fallback

  defp async_loading?(%AsyncResult{loading: loading}), do: not is_nil(loading)
  defp async_loading?(_result), do: false

  defp async_failed?(%AsyncResult{failed: failed}), do: not is_nil(failed)
  defp async_failed?(_result), do: false

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp current_actor(socket), do: socket.assigns[:current_user]

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}) do
    Enum.map(errors, &translate_error/1)
  end

  defp translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(GSMLG.AdminWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(GSMLG.AdminWeb.Gettext, "errors", msg, opts)
    end
  end

  defp format_dt(nil), do: "-"
  defp format_dt(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_dt(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp note_labels(%Note{} = note) do
    labels =
      case note.labels do
        %Ecto.Association.NotLoaded{} -> []
        nil -> []
        labels -> labels
      end

    labels =
      if labels == [] do
        note.labels
        |> loaded_list()
        |> Enum.map(&%{key: &1.name, value: "", status: "valid", errors: []})
      else
        Enum.map(labels, fn
          %Label{label_setting: %LabelSetting{} = label_setting} = label ->
            %{
              key: label_setting.name,
              value: label.value || "",
              status: label.status || "valid",
              errors: label.errors || []
            }

          _label ->
            nil
        end)
        |> Enum.reject(&is_nil/1)
      end

    Enum.sort_by(labels, &LabelSetting.normalized_key(&1.key))
  end

  defp loaded_list(%Ecto.Association.NotLoaded{}), do: []
  defp loaded_list(nil), do: []
  defp loaded_list(list), do: list

  defp label_text(%{key: key, value: ""}), do: key
  defp label_text(%{key: key, value: value}), do: "#{key}=#{value}"

  defp label_variant(%{status: "invalid"}), do: "error"
  defp label_variant(_label), do: "primary"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} page_title={@page_title} active_menu={@active_menu}>
      <div :if={@live_action == :index} class="flex flex-col gap-4 p-6 w-full">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="notebook-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">GaoNote</h1>
          </div>
          <.link patch={~p"/gao_notes/notes/new"}>
            <.dm_btn variant="primary" size="sm">
              <.dm_mdi name="plus" class="w-4 h-4" /> New
            </.dm_btn>
          </.link>
        </div>

        <form
          id="gao-note-filter-form"
          phx-change="search_form_changed"
          phx-submit="search"
          class="grid gap-2 rounded-xl bg-base-200/60 p-3"
        >
          <div class="grid grid-cols-[minmax(0,1fr)_auto_auto] gap-2">
            <.dm_input
              id="gao-note-search-input"
              name="filters[search]"
              value={@filters["search"]}
              placeholder="Search notes"
              aria-label="Search notes"
            />
            <.dm_btn type="submit" variant="primary">
              <.dm_mdi name="magnify" class="h-4 w-4" /> Search
            </.dm_btn>
            <.dm_btn type="button" variant="ghost" phx-click="clear_search_filters">
              Clear
            </.dm_btn>
          </div>

          <div class="grid gap-2 sm:grid-cols-[minmax(0,1fr)_5rem_minmax(0,1fr)_auto]">
            <.dm_input
              id="gao-note-filter-key"
              name="label_filter[key]"
              value={@label_filter_key}
              placeholder="key"
              aria-label="Label key"
            />
            <.dm_select
              id="gao-note-filter-operator"
              name="label_filter[operator]"
              value={@label_filter_operator}
              options={[{"=", "="}]}
              aria-label="Label operator"
            />
            <.dm_input
              id="gao-note-filter-value"
              name="label_filter[value]"
              value={@label_filter_value}
              placeholder="value (optional)"
              aria-label="Label value (optional)"
            />
            <.dm_btn type="button" variant="secondary" phx-click="add_search_filter">
              Add filter
            </.dm_btn>
          </div>

          <input
            :for={label_filter <- @filters["labels"]}
            type="hidden"
            name="filters[labels][]"
            value={label_filter}
          />

          <div :if={@filters["labels"] != []} class="flex flex-wrap gap-2">
            <.dm_badge
              :for={label_filter <- @filters["labels"]}
              variant="primary"
              soft
              class="gap-1"
            >
              <span>{label_filter}</span>
              <button
                type="button"
                class="rounded-full"
                phx-click="remove_search_filter"
                phx-value-filter={label_filter}
                aria-label={"Remove filter #{label_filter}"}
              >
                <.dm_mdi name="close" class="h-3 w-3" />
              </button>
            </.dm_badge>
          </div>
        </form>

        <.dm_skeleton_table
          :if={async_loading?(@notes)}
          id="gao-note-table-loading"
          rows={6}
          columns={6}
          animation="wave"
          loading_label="Loading GaoNote notes"
        />
        <div :if={async_failed?(@notes)} class="text-sm text-error">
          Unable to load notes.
        </div>

        <.dm_table
          :if={!async_loading?(@notes)}
          id="gao-note-table"
          class="table-bordered"
          data={async_value(@notes, [])}
        >
          <:col :let={note} label="Title">
            <.link
              patch={~p"/gao_notes/notes/#{note.id}/show"}
              class="font-medium text-sm text-primary hover:underline"
            >
              {note.title}
            </.link>
          </:col>
          <:col :let={note} label="Labels">
            <div class="flex min-w-32 max-w-56 flex-wrap gap-1">
              <.dm_badge :for={label <- note_labels(note)} variant={label_variant(label)} soft>
                {label_text(label)}
              </.dm_badge>
              <span :if={note_labels(note) == []} class="text-xs text-base-content/40">None</span>
            </div>
          </:col>
          <:col :let={note} label="Created">
            <span class="font-mono text-xs">{format_dt(note.created_at)}</span>
          </:col>
          <:col :let={note} label="Updated">
            <span class="font-mono text-xs">{format_dt(note.updated_at)}</span>
          </:col>
          <:col :let={note} label="">
            <div class="flex items-center gap-1">
              <.link patch={~p"/gao_notes/notes/#{note.id}/show"}>
                <.dm_btn size="xs" variant="ghost" title="View">
                  <.dm_mdi name="eye-outline" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.link patch={~p"/gao_notes/notes/#{note.id}/edit"}>
                <.dm_btn size="xs" variant="ghost" title="Edit">
                  <.dm_mdi name="pencil-outline" class="w-3.5 h-3.5" />
                </.dm_btn>
              </.link>
              <.dm_modal
                id={"confirm-dialog-gao-note-list-delete-#{note.id}"}
                size="sm"
                hide_close
                dialog_label="Delete GaoNote"
              >
                <:trigger :let={dialog_id}>
                  <.dm_btn
                    id={"gao-note-list-delete-#{note.id}"}
                    size="xs"
                    variant="ghost"
                    class="text-error"
                    title="Delete"
                    onclick={"document.getElementById('#{dialog_id}').show()"}
                  >
                    <.dm_mdi name="trash-can-outline" class="w-3.5 h-3.5" />
                  </.dm_btn>
                </:trigger>
                <:title>Delete GaoNote</:title>
                <:body>
                  <p class="text-sm text-base-content/80">Delete this GaoNote?</p>
                </:body>
                <:footer>
                  <div class="flex justify-end gap-2">
                    <form id={"gao-note-delete-list-cancel-#{note.id}"} method="dialog">
                      <button
                        type="button"
                        class="btn btn-ghost btn-sm"
                        onclick={"document.getElementById('confirm-dialog-gao-note-list-delete-#{note.id}').close()"}
                      >
                        Cancel
                      </button>
                    </form>
                    <form id={"gao-note-delete-list-confirm-#{note.id}"} method="dialog">
                      <.dm_btn
                        type="submit"
                        variant="error"
                        size="sm"
                        phx-click="delete"
                        phx-value-id={note.id}
                      >
                        Delete
                      </.dm_btn>
                    </form>
                  </div>
                </:footer>
              </.dm_modal>
            </div>
          </:col>
        </.dm_table>
      </div>

      <div :if={@live_action in [:new, :edit]} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="sticky top-0 z-20 flex flex-wrap items-center justify-between gap-3 border-b border-outline-variant bg-surface py-3 text-on-surface">
          <div class="flex items-center gap-3">
            <.dm_mdi name="notebook-edit-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">{@page_title}</h1>
          </div>
          <div class="flex items-center gap-2">
            <.dm_btn variant="ghost" type="button" phx-click="cancel_note">Cancel</.dm_btn>
            <button type="submit" form="gao-note-form" class="btn btn-primary">Save</button>
          </div>
        </div>

        <div class="flex gap-2">
          <.dm_btn size="sm" variant="ghost" type="button" phx-click="cancel_note">
            <.dm_mdi name="arrow-left" class="w-4 h-4" /> All Notes
          </.dm_btn>
        </div>

        <.dm_form
          id="gao-note-form"
          for={@form}
          phx-submit="save"
          phx-change="validate"
          class="grid gap-4"
        >
          <.dm_input field={@form[:title]} label="Title" errors={field_errors(@form[:title])} />

          <div class="grid gap-2">
            <.dm_label for="gao-note-labels">Labels</.dm_label>
            <.dm_multi_select
              id="gao-note-labels"
              name="gao_note[labels]"
              options={async_value(@label_options, selected_label_options(@selected_labels))}
              selected={@selected_labels}
              placeholder="Select labels"
              searchable
              show_counter
              clearable
              tag_variant="primary"
              phx-hook="GaoNoteLabelsMultiSelect"
            />
            <div
              :if={async_loading?(@label_options)}
              id="gao-note-labels-loading"
              class="text-sm text-base-content/60"
            >
              Loading labels
            </div>
            <div :if={async_failed?(@label_options)} class="text-sm text-error">
              Unable to load labels.
            </div>
            <div class="grid grid-cols-[minmax(0,1fr)_auto_minmax(0,1fr)_auto] items-end gap-2">
              <.dm_input
                id="gao-note-label-key-input"
                name="label_key_input"
                value={@label_key_input}
                label="Label key"
                autocomplete="off"
                phx-change="label_input_changed"
              />
              <span class="flex h-12 items-center text-base-content/60">=</span>
              <.dm_input
                id="gao-note-label-value-input"
                name="label_value_input"
                value={@label_value_input}
                label="Label value"
                autocomplete="off"
                phx-change="label_input_changed"
              />
              <.dm_btn
                type="button"
                variant="secondary"
                phx-click="add_label_option"
                phx-value-key={@label_key_input}
                phx-value-value={@label_value_input}
              >
                <.dm_mdi name="plus" class="w-4 h-4" /> Add
              </.dm_btn>
            </div>
          </div>

          <% content_errors = field_errors(@form[:content]) %>
          <div class="grid gap-2" phx-feedback-for={@form[:content].name}>
            <.dm_label for={@form[:content].id}>Markdown Content</.dm_label>
            <.dm_markdown_input
              field={@form[:content]}
              placeholder="Write markdown content"
              theme="auto"
              resize="vertical"
              live_preview
              debounce={250}
              class="min-h-[28rem]"
              aria-invalid={content_errors != [] && "true"}
              aria-describedby={content_errors != [] && "#{@form[:content].id}-errors"}
            />
            <div :if={content_errors != []} id={"#{@form[:content].id}-errors"}>
              <.dm_error :for={msg <- content_errors}>{msg}</.dm_error>
            </div>
          </div>
        </.dm_form>

        <.attachment_editor
          attachments={attachment_cards(@attachment_drafts, @attachment_order, @note)}
          form={@attachment_form}
          modal={@attachment_modal}
          errors={@attachment_errors}
          save_error={@attachment_save_error}
          upload={@uploads.attachment}
        />
      </div>

      <div :if={@live_action == :show} class="flex flex-col gap-4 p-6 w-full max-w-5xl">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <.dm_mdi name="notebook-outline" class="w-5 h-5 text-primary" />
            <h1 class="font-semibold text-base-content">{@note.title}</h1>
          </div>
        </div>

        <div class="flex flex-wrap gap-2">
          <.link patch={~p"/gao_notes/notes"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="arrow-left" class="w-4 h-4" /> All Notes
            </.dm_btn>
          </.link>
          <.link patch={~p"/gao_notes/notes/#{@note.id}/edit"}>
            <.dm_btn size="sm" variant="ghost">
              <.dm_mdi name="pencil-outline" class="w-4 h-4" /> Edit
            </.dm_btn>
          </.link>
          <.dm_modal
            id={"confirm-dialog-gao-note-delete-#{@note.id}"}
            size="sm"
            hide_close
            dialog_label="Delete GaoNote"
          >
            <:trigger :let={dialog_id}>
              <.dm_btn
                id={"gao-note-delete-#{@note.id}"}
                size="sm"
                variant="ghost"
                class="text-error"
                onclick={"document.getElementById('#{dialog_id}').show()"}
              >
                <.dm_mdi name="trash-can-outline" class="w-4 h-4" /> Delete
              </.dm_btn>
            </:trigger>
            <:title>Delete GaoNote</:title>
            <:body>
              <p class="text-sm text-base-content/80">Delete this GaoNote?</p>
            </:body>
            <:footer>
              <div class="flex justify-end gap-2">
                <form id={"gao-note-delete-cancel-#{@note.id}"} method="dialog">
                  <button
                    type="button"
                    class="btn btn-ghost btn-sm"
                    onclick={"document.getElementById('confirm-dialog-gao-note-delete-#{@note.id}').close()"}
                  >
                    Cancel
                  </button>
                </form>
                <form id={"gao-note-delete-confirm-#{@note.id}"} method="dialog">
                  <.dm_btn
                    type="submit"
                    variant="error"
                    size="sm"
                    phx-click="delete"
                    phx-value-id={@note.id}
                  >
                    Delete
                  </.dm_btn>
                </form>
              </div>
            </:footer>
          </.dm_modal>
        </div>

        <div class="grid gap-3 md:grid-cols-2">
          <div>
            <div class="font-mono text-xs text-base-content/50">Created</div>
            <div class="font-mono text-xs">{format_dt(@note.created_at)}</div>
          </div>
          <div>
            <div class="font-mono text-xs text-base-content/50">Updated</div>
            <div class="font-mono text-xs">{format_dt(@note.updated_at)}</div>
          </div>
        </div>

        <div :if={note_labels(@note) != []} class="flex flex-wrap gap-2">
          <.dm_badge :for={label <- note_labels(@note)} variant={label_variant(label)} soft>
            {label_text(label)}
          </.dm_badge>
        </div>

        <div
          id={"gao-note-content-#{@note.id}"}
          class="prose block w-full max-w-none text-on-surface"
        >
          {rendered_note_content(@note)}
        </div>

        <section
          :if={show_attachment_cards(@note) != []}
          id="note-attachments"
          class="mt-4 grid gap-4 rounded-2xl border border-outline-variant bg-surface-container-low p-4 text-on-surface sm:p-5"
        >
          <div>
            <h2 class="text-lg font-semibold">Attachments</h2>
            <p class="mt-1 text-sm text-on-surface-variant">
              Files owned by this note, including files not referenced in its content.
            </p>
          </div>
          <div class="grid grid-cols-1 gap-3 md:grid-cols-2 xl:grid-cols-3">
            <.dm_card
              :for={attachment <- show_attachment_cards(@note)}
              id={"note-attachment-#{attachment.ref}"}
              variant="bordered"
              class="h-full min-w-0 bg-surface-container text-on-surface"
              body_class="grid h-full gap-3"
            >
              <dl class="grid gap-3 text-sm">
                <div>
                  <dt class="font-medium">Path</dt>
                  <dd class="break-all font-mono text-xs text-on-surface-variant">
                    {attachment.path}
                  </dd>
                </div>
                <div>
                  <dt class="font-medium">MIME</dt>
                  <dd class="break-all font-mono text-xs text-on-surface-variant">
                    {attachment.mime}
                  </dd>
                </div>
                <div>
                  <dt class="font-medium">Description</dt>
                  <dd class="break-words text-on-surface-variant">
                    {if attachment.description == "",
                      do: "No description",
                      else: attachment.description}
                  </dd>
                </div>
              </dl>
              <:action>
                <a
                  href={attachment.raw_url}
                  download={Path.basename(attachment.path)}
                  class="btn btn-secondary btn-sm"
                >
                  Download
                </a>
              </:action>
            </.dm_card>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
