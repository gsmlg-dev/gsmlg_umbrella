defmodule GSMLG.GaoNote.Presenter do
  @moduledoc """
  Serializes GaoNote domain structs for LiveView and MCP surfaces.
  """

  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note}
  alias GSMLG.Storage.StorageFile

  def note(%Note{} = note) do
    labels = labels(note)

    %{
      "id" => note.id,
      "title" => note.title,
      "description" => note.description,
      "labels" => labels,
      "content" => note.content,
      "creator" => note.creator,
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
    %{
      "id" => attachment.id,
      "role" => attachment.role,
      "description" => attachment.description || "",
      "path" => attachment.path,
      "caption" => attachment.caption,
      "alt_text" => attachment.alt_text,
      "position" => attachment.position,
      "metadata" => attachment.metadata || %{},
      "storage_file" => attachment |> loaded_storage_file() |> storage_file()
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

  defp storage_file(%StorageFile{} = file) do
    visibility = storage_visibility(file)

    %{
      "id" => file.id,
      "filename" => file.filename,
      "content_type" => file.content_type,
      "size" => file.size,
      "visibility" => visibility,
      "inserted_at" => format_datetime(file.inserted_at),
      "updated_at" => format_datetime(file.updated_at)
    }
    |> maybe_put_public_content(file, visibility)
  end

  defp storage_file(_file), do: nil

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
  end

  defp loaded_storage_file(%Attachment{storage_file: %StorageFile{} = file}), do: file
  defp loaded_storage_file(_attachment), do: nil

  defp storage_visibility(%StorageFile{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "visibility") || Map.get(metadata, :visibility)
  end

  defp storage_visibility(_file), do: nil

  defp maybe_put_public_content(presented, file, "public") do
    case Map.fetch(file, :content) do
      {:ok, content} -> Map.put(presented, "content", content)
      :error -> presented
    end
  end

  defp maybe_put_public_content(presented, _file, _visibility), do: presented

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
