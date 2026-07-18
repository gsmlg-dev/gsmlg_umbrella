defmodule GSMLG.Web.GaoNoteController do
  use GSMLG.Web, :controller

  alias GSMLG.GaoNote
  alias GSMLG.Web.Guardian

  action_fallback(GSMLG.Web.FallbackController)

  @write_keys ~w(title content labels attachments)
  @attachment_write_keys ~w(id path mime description content content_base64)
  @malformed_codes [:must_be_a_list, :unsupported_content_source]
  @conflict_codes [:duplicate_id, :duplicate_path, :owned_by_another_note, :stale]
  @semantic_codes [
    :content_required,
    :mime_mismatch,
    :retained_mime_mismatch
  ]
  @internal_codes [:content_read_failed, :staging_failed]
  @malformed_base64_message "must be standard padded Base64"

  def index(conn, params) do
    notes =
      params
      |> list_opts()
      |> GaoNote.list_public_notes()

    render(conn, :index, notes: notes)
  end

  def show(conn, %{"id" => id}) do
    with %{} = note <- GaoNote.get_public_note(id) do
      render(conn, :show, note: note)
    else
      nil -> {:error, :not_found}
    end
  end

  def label_settings(conn, params) do
    label_settings = GaoNote.list_label_settings(limit: Map.get(params, "limit"))

    render(conn, :label_settings, label_settings: label_settings)
  end

  def create(conn, params) do
    actor = authenticated_actor!(conn)

    with {:ok, attrs} <- note_attrs(conn, params),
         {:ok, note} <- GaoNote.create_note(attrs, actor) do
      conn
      |> put_status(:created)
      |> render(:show, note: note)
    else
      {:error, reason} ->
        render_write_error(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    actor = authenticated_actor!(conn)

    case GaoNote.get_note(id) do
      nil ->
        {:error, :not_found}

      note ->
        with {:ok, attrs} <- note_attrs(conn, params),
             {:ok, updated_note} <- GaoNote.update_note(note, attrs, actor) do
          render(conn, :show, note: updated_note)
        else
          {:error, reason} -> render_write_error(conn, reason)
        end
    end
  end

  defp list_opts(params) do
    [
      search: Map.get(params, "search", Map.get(params, "query")),
      label: Map.get(params, "label"),
      limit: Map.get(params, "limit"),
      offset: Map.get(params, "offset")
    ]
  end

  defp authenticated_actor!(conn) do
    case Guardian.Plug.current_resource(conn) do
      %{} = actor -> actor
      _missing -> raise "authenticated GaoNote route has no Guardian resource"
    end
  end

  defp note_attrs(conn, params) do
    params = body_params(conn, params)
    attrs = Map.take(params, @write_keys)

    with :ok <- validate_top_level_fields(params) do
      case Map.fetch(attrs, "attachments") do
        :error ->
          {:ok, attrs}

        {:ok, attachments} ->
          with {:ok, attachments} <- validate_external_attachments(attachments) do
            {:ok, Map.put(attrs, "attachments", attachments)}
          end
      end
    end
  end

  defp body_params(%{body_params: %Plug.Conn.Unfetched{} = _unfetched, path_params: path_params}, params),
    do: Map.drop(params, Map.keys(path_params))

  defp body_params(%{body_params: body_params}, _params) when is_map(body_params),
    do: body_params

  defp validate_top_level_fields(params) do
    case unknown_fields(params, @write_keys) do
      [] ->
        :ok

      fields ->
        {:error, {:note_params, %{unknown_fields: fields}}}
    end
  end

  defp validate_external_attachments(attachments) when is_list(attachments) do
    attachments
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {attachment, index}, {:ok, validated} ->
      case validate_external_attachment(attachment, index) do
        {:ok, attachment} -> {:cont, {:ok, [attachment | validated]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, validated} -> {:ok, Enum.reverse(validated)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_external_attachments(attachments), do: {:ok, attachments}

  defp validate_external_attachment(attachment, index) when is_map(attachment) do
    case unknown_fields(attachment, @attachment_write_keys) do
      [] ->
        {:ok, Map.take(attachment, @attachment_write_keys)}

      fields ->
        {:error,
         {:attachment_params,
          %{
            index: index,
            unknown_fields: fields
          }}}
    end
  end

  defp validate_external_attachment(attachment, _index), do: {:ok, attachment}

  defp unknown_fields(params, allowed_fields) do
    params
    |> Map.keys()
    |> Enum.reject(&(&1 in allowed_fields))
    |> Enum.map(fn
      field when is_binary(field) -> field
      _non_string_field -> "<non-string>"
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp render_write_error(conn, {:note_params, %{unknown_fields: fields}}) do
    json_error(conn, :bad_request, %{
      code: "unknown_fields",
      fields: fields
    })
  end

  defp render_write_error(
         conn,
         {:attachment_params, %{index: index, unknown_fields: fields}}
       ) do
    json_error(conn, :bad_request, %{
      attachments: [
        %{
          index: index,
          code: "unknown_fields",
          fields: fields
        }
      ]
    })
  end

  defp render_write_error(conn, %Ecto.Changeset{} = changeset) do
    cond do
      unique_conflict?(changeset) ->
        json_error(conn, :conflict, %{
          code: "unique_conflict",
          detail: "Conflict"
        })

      malformed_changeset?(changeset) ->
        json_error(conn, :bad_request, changeset_errors(changeset))

      true ->
        conn
        |> put_status(:unprocessable_entity)
        |> put_view(json: GSMLG.Web.ChangesetJSON)
        |> render("error.json", changeset: changeset)
    end
  end

  defp render_write_error(
         conn,
         {:attachment_input, %{index: index, changeset: %Ecto.Changeset{} = changeset}}
       ) do
    status = if malformed_changeset?(changeset), do: :bad_request, else: :unprocessable_entity

    json_error(conn, status, %{
      attachments: [
        %{
          index: index,
          code: "invalid",
          fields: changeset_errors(changeset)
        }
      ]
    })
  end

  defp render_write_error(conn, {:attachments, %{code: :required}}) do
    json_error(conn, :bad_request, %{attachments: ["is required"]})
  end

  defp render_write_error(conn, {_kind, %{code: code}})
       when code in @malformed_codes do
    json_error(conn, :bad_request, %{
      code: Atom.to_string(code),
      detail: "Malformed request"
    })
  end

  defp render_write_error(conn, {_kind, %{code: code}})
       when code in @conflict_codes do
    json_error(conn, :conflict, %{
      code: Atom.to_string(code),
      detail: "Attachment conflict"
    })
  end

  defp render_write_error(conn, {_kind, %{code: code}})
       when code in @semantic_codes do
    json_error(conn, :unprocessable_entity, %{
      attachments: [
        %{
          code: Atom.to_string(code),
          detail: "Attachment validation failed"
        }
      ]
    })
  end

  defp render_write_error(conn, {_kind, %{code: code}})
       when code in @internal_codes do
    internal_server_error(conn)
  end

  defp render_write_error(conn, {_kind, %{code: code}}) when is_atom(code),
    do: internal_server_error(conn)

  defp render_write_error(_conn, :not_found), do: {:error, :not_found}
  defp render_write_error(conn, _reason), do: internal_server_error(conn)

  defp json_error(conn, status, errors) do
    conn
    |> put_status(status)
    |> json(%{errors: errors})
  end

  defp internal_server_error(conn) do
    json_error(conn, :internal_server_error, %{detail: "Internal Server Error"})
  end

  defp malformed_changeset?(changeset) do
    Enum.any?(changeset.errors, fn
      {:content_base64, {message, metadata}} ->
        message == @malformed_base64_message and metadata == []

      _error ->
        false
    end)
  end

  defp unique_conflict?(changeset) do
    Enum.any?(changeset.errors, fn {_field, {_message, metadata}} ->
      Keyword.get(metadata, :constraint) == :unique
    end)
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Enum.reduce(opts, message, fn {key, value}, rendered ->
        String.replace(rendered, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
