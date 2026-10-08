defmodule GSMLG.Web.AgentNoteController do
  use GSMLG.Web, :controller

  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Presenter
  alias GSMLG.Web.AgentNoteContent

  def index(conn, params), do: read_list(conn, params, &Compat.list_notes/1, &Presenter.summary/1)

  def trash(conn, _params),
    do: read_list(conn, %{}, &Compat.list_deleted_notes/1, &Presenter.trash/1)

  def count(conn, params) do
    with :ok <- query_numbers(params), {:ok, total} <- Compat.count_notes(params) do
      json(conn, %{total: total})
    else
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def show(conn, %{"id" => id}) do
    case Compat.get_note_metadata(id) do
      nil -> plain(conn, 404, "note not found")
      note -> json(conn, Presenter.note(note))
    end
  end

  def create(conn, params) do
    result = with :ok <- note_shape(params), do: Compat.save_note(params, actor(conn))

    case result do
      {:ok, note} -> json(conn, %{id: note.id})
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    attrs = params |> Map.put_new("labels", []) |> Map.put_new("attachments", [])

    with {:ok, revision} <- revision(params, :body),
         :ok <- note_shape(attrs),
         {:ok, %{note: note}} <- Compat.replace_note(id, revision, attrs, actor(conn)) do
      json(conn, Presenter.note(note))
    else
      {:error, reason} -> mutation_error(conn, reason, id)
    end
  end

  def delete(conn, %{"id" => id} = params), do: lifecycle(conn, params, id, &Compat.delete_note/3)

  def purge(conn, %{"id" => id} = params),
    do: lifecycle(conn, params, id, &Compat.permanently_delete_note/3)

  def restore(conn, params) do
    notes = params["notes"]

    result =
      if is_list(notes) and
           Enum.all?(notes, fn target ->
             is_map(target) and is_binary(target["id"]) and
               is_integer(target["expected_revision"]) and target["expected_revision"] > 0 and
               target["expected_revision"] <= 9_223_372_036_854_775_807
           end) do
        notes =
          Enum.uniq_by(notes, fn target -> if is_map(target), do: target["id"], else: target end)

        if notes == [],
          do: {:error, {:invalid_input, "at least one note id is required"}},
          else: Compat.restore_notes(%{"notes" => notes}, actor(conn))
      else
        {:error, {:invalid_input, "notes must be an array"}}
      end

    case result do
      {:ok, _} -> send_resp(conn, 204, "")
      {:error, reason} -> mutation_error(conn, reason)
    end
  end

  def bulk_labels(conn, params) do
    case Compat.bulk_update_note_labels(params, actor(conn)) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def batch_labels(conn, params), do: batch(conn, params, &Compat.batch_update_note_labels/2)
  def batch_delete(conn, params), do: batch(conn, params, &Compat.batch_delete_notes/2)

  def labels(conn, _params) do
    with {:ok, settings} <- Compat.list_label_keys() do
      json(conn, Enum.map(settings, &Presenter.label_setting/1))
    else
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def define_label(conn, params) do
    with {:ok, attrs} <- catalog_attrs(params),
         {:ok, _} <- Compat.define_label_key(params["key"], attrs, actor(conn)) do
      send_resp(conn, 200, "")
    else
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def update_label(conn, %{"key" => key} = params) do
    with {:ok, attrs} <- catalog_attrs(params),
         {:ok, _} <- Compat.update_label_key(key, attrs, actor(conn)) do
      send_resp(conn, 200, "")
    else
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def delete_label(conn, %{"key" => key}) do
    case Compat.delete_label_key(key, actor(conn)) do
      {:ok, _} -> send_resp(conn, 200, "")
      {:error, reason} -> read_error(conn, reason)
    end
  end

  def raw(conn, params), do: AgentNoteContent.raw(conn, params)
  def render(conn, params), do: AgentNoteContent.render(conn, params)
  def dashboard(conn, params), do: AgentNoteContent.dashboard(conn, params)
  def capabilities(conn, params), do: AgentNoteContent.capabilities(conn, params)
  def pdf(conn, params), do: AgentNoteContent.pdf(conn, params)

  def search(conn, params) do
    case GSMLG.GaoNote.Compat.Search.search_notes(params) do
      {:ok, results} ->
        json(
          conn,
          Enum.map(results, fn %{note: note, score: score} ->
            Map.put(Presenter.summary(note), :score, score)
          end)
        )

      {:error, reason} ->
        read_error(conn, reason)
    end
  end

  defp read_list(conn, params, fetch, present) do
    with :ok <- query_numbers(params), {:ok, notes} <- fetch.(params) do
      json(conn, Enum.map(notes, present))
    else
      {:error, reason} -> read_error(conn, reason)
    end
  end

  defp lifecycle(conn, params, id, operation) do
    with {:ok, revision} <- revision(params, :query),
         {:ok, _} <- operation.(id, revision, actor(conn)) do
      send_resp(conn, 204, "")
    else
      {:error, reason} -> mutation_error(conn, reason, id)
    end
  end

  defp batch(conn, params, operation) do
    case operation.(params, actor(conn)) do
      {:ok, result} -> json(conn, result)
      {:error, reason} -> mutation_error(conn, reason)
    end
  end

  defp note_shape(params) do
    labels = Map.get(params, "labels", [])
    attachments = Map.get(params, "attachments", [])

    cond do
      not is_binary(params["title"]) or not is_binary(params["content"]) ->
        {:error, {:invalid_input, "title and content must be strings"}}

      not is_list(labels) or
          not Enum.all?(labels, fn value ->
            match?([key, text] when is_binary(key) and is_binary(text), value)
          end) ->
        {:error, {:invalid_input, "labels must be an array of string pairs"}}

      not is_list(attachments) ->
        {:error, {:invalid_input, "attachments must be an array"}}

      true ->
        Enum.reduce_while(attachments, :ok, fn input, :ok ->
          if is_map(input) and
               Enum.all?(
                 Map.keys(input),
                 &(&1 in ~w(id path mime description content content_base64))
               ) and
               (is_binary(input["content"]) or is_binary(input["content_base64"])) do
            case GSMLG.GaoNote.AttachmentInput.cast(input) do
              {:ok, _} -> {:cont, :ok}
              {:error, _} -> {:halt, {:error, {:invalid_input, "invalid attachment"}}}
            end
          else
            {:halt,
             {:error,
              {:invalid_input, "attachment requires content or content_base64 and valid fields"}}}
          end
        end)
    end
  end

  defp catalog_attrs(params) do
    type = params["value_type"] || "text"

    if is_binary(params["description"]) and type in ~w(text number date time datetime version) do
      {:ok,
       %{
         description: params["description"],
         value_type: if(type == "datetime", do: "date-time", else: type)
       }}
    else
      {:error, {:invalid_input, "invalid label description or value_type"}}
    end
  end

  defp query_numbers(params) do
    if Enum.all?(~w(limit offset), fn key ->
         case Map.fetch(params, key) do
           :error ->
             true

           {:ok, value} when is_integer(value) ->
             value >= -9_223_372_036_854_775_808 and value <= 9_223_372_036_854_775_807

           {:ok, value} when is_binary(value) ->
             match?(
               {n, ""} when n >= -9_223_372_036_854_775_808 and n <= 9_223_372_036_854_775_807,
               Integer.parse(value)
             )

           _ ->
             false
         end
       end),
       do: :ok,
       else: {:error, {:invalid_input, "Invalid query parameters"}}
  end

  defp revision(params, source) do
    case Map.fetch(params, "expected_revision") do
      :error ->
        {:error, :expected_revision_required}

      {:ok, value} when source == :query and is_binary(value) ->
        case Integer.parse(value) do
          {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 -> {:ok, number}
          _ -> {:error, :expected_revision_required}
        end

      {:ok, value} when is_integer(value) and value > 0 and value <= 9_223_372_036_854_775_807 ->
        {:ok, value}

      _ ->
        {:error, {:invalid_input, "expected_revision must be a positive integer"}}
    end
  end

  defp actor(conn), do: Guardian.Plug.current_resource(conn)

  defp read_error(conn, {:validation_error, message}), do: plain(conn, 400, message)
  defp read_error(conn, {:invalid_input, message}), do: plain(conn, 400, message)
  defp read_error(conn, %Ecto.Changeset{}), do: plain(conn, 400, "invalid note or label")

  defp read_error(conn, {:category_label_in_use, %{message: message}}),
    do: plain(conn, 400, message)

  defp read_error(conn, :not_found), do: plain(conn, 404, "note not found")

  defp read_error(conn, :search_unavailable),
    do: plain(conn, 500, "note search service unavailable")

  defp read_error(conn, _), do: plain(conn, 500, "note storage operation failed")

  defp mutation_error(conn, reason, id \\ nil)

  defp mutation_error(conn, :expected_revision_required, _),
    do: error(conn, 400, "expected_revision_required", "expected_revision is required", %{})

  defp mutation_error(conn, {:invalid_input, message}, _),
    do: error(conn, 400, "invalid_input", message, %{})

  defp mutation_error(conn, {:validation_error, message}, _),
    do: error(conn, 400, "invalid_input", message, %{})

  defp mutation_error(conn, %Ecto.Changeset{}, _),
    do: error(conn, 400, "invalid_input", "invalid note", %{})

  defp mutation_error(conn, :not_found, id),
    do: error(conn, 404, "not_found", "note not found", %{note_id: id})

  defp mutation_error(conn, {:revision_conflict, details}, _),
    do: error(conn, 409, "revision_conflict", "the note changed after it was read", details)

  defp mutation_error(conn, _, _),
    do: error(conn, 500, "storage_failure", "note storage operation failed", %{}, true)

  defp error(conn, status, code, message, details, retryable \\ false),
    do:
      conn
      |> put_status(status)
      |> json(%{code: code, message: message, details: details, retryable: retryable})

  defp plain(conn, status, message),
    do: conn |> put_resp_content_type("text/plain") |> send_resp(status, message)
end
