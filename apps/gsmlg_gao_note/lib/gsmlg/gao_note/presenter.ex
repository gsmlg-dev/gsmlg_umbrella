defmodule GSMLG.GaoNote.Presenter do
  @moduledoc """
  Serializes GaoNote domain structs for LiveView and MCP surfaces.
  """

  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note}

  def note(%Note{} = note) do
    labels = labels(note)

    %{
      "id" => note.id,
      "title" => note.title,
      "labels" => labels,
      "content" => note.content,
      "attachments" => attachments(note),
      "created_at" => format_datetime(note.created_at),
      "updated_at" => format_datetime(note.updated_at)
    }
  end

  def note_summary(%Note{} = note) do
    note(note)
  end

  def label_setting(%LabelSetting{} = label_setting) do
    %{
      "id" => label_setting.id,
      "name" => label_setting.name,
      "key" => label_setting.name,
      "color" => label_setting.color,
      "description" => label_setting.description || "",
      "value_type" => label_setting.value_type || "text",
      "metadata" => label_setting.metadata || %{}
    }
  end

  def label(%Label{label_setting: %LabelSetting{} = label_setting} = label) do
    %{
      "key" => label_setting.name,
      "value" => label.value || "",
      "value_type" => label_setting.value_type || "text",
      "description" => label_setting.description || "",
      "status" => label.status || "valid",
      "errors" => label.errors || []
    }
  end

  def label(%LabelSetting{} = label_setting) do
    %{
      "key" => label_setting.name,
      "value" => "",
      "value_type" => label_setting.value_type || "text",
      "description" => label_setting.description || "",
      "status" => "valid",
      "errors" => []
    }
  end

  def attachment(%Attachment{} = attachment) do
    path =
      attachment.path
      |> to_string()

    %{
      "id" => attachment.id,
      "path" => path,
      "mime" => attachment.mime,
      "description" => attachment.description || "",
      "content_url" => content_url(attachment.note_id, path)
    }
  end

  def error_text(%Ecto.Changeset{} = changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> inspect()
  end

  def error_text(reason), do: inspect(reason)

  defp labels(%Note{} = note) do
    labels =
      note
      |> loaded_list(:labels)
      |> Enum.filter(&match?(%Label{label_setting: %LabelSetting{}}, &1))

    labels = Enum.map(labels, &label/1)

    Enum.sort_by(labels, &LabelSetting.normalized_key(&1["key"]))
  end

  defp attachments(%Note{} = note) do
    note
    |> loaded_list(:attachments)
    |> Enum.filter(&match?(%Attachment{}, &1))
    |> Enum.map(&attachment/1)
    |> Enum.sort_by(fn attachment -> {attachment["path"], attachment["id"]} end)
  end

  defp content_url(note_id, path) do
    encoded_note_id = URI.encode(to_string(note_id), &URI.char_unreserved?/1)

    encoded_path =
      path
      |> content_url_path()
      |> URI.encode(fn character ->
        character == ?/ or URI.char_unreserved?(character)
      end)

    "/api/gao_notes/#{encoded_note_id}/attachments/#{encoded_path}"
  end

  defp content_url_path("./" <> path), do: path
  defp content_url_path(path), do: path

  defp loaded_list(struct, key) do
    case Map.get(struct, key) do
      %Ecto.Association.NotLoaded{} -> []
      nil -> []
      list -> list
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp format_datetime(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_iso8601(datetime)
end
