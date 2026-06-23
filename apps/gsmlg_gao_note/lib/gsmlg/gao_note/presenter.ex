defmodule GSMLG.GaoNote.Presenter do
  @moduledoc """
  Serializes GaoNote domain structs for LiveView and MCP surfaces.
  """

  alias GSMLG.GaoNote.{Asset, Note, Reference, Tag}
  alias GSMLG.Storage.StorageFile

  def note(%Note{} = note) do
    tags =
      note
      |> loaded_list(:tags)
      |> Enum.sort_by(&Tag.normalized_key(&1.name))
      |> Enum.map(&tag/1)

    %{
      "id" => note.id,
      "title" => note.title,
      "description" => note.description,
      "content" => note.content,
      "creator" => note.creator,
      "tags" => tags,
      "created_at" => format_datetime(note.created_at),
      "updated_at" => format_datetime(note.updated_at)
    }
  end

  def note_summary(%Note{} = note) do
    note(note)
  end

  def tag(%Tag{} = tag) do
    %{
      "id" => tag.id,
      "name" => tag.name,
      "color" => tag.color,
      "metadata" => tag.metadata || %{}
    }
  end

  def reference(%Reference{} = reference) do
    %{
      "id" => reference.id,
      "note_id" => reference.note_id,
      "url" => reference.url,
      "canonical_url" => reference.canonical_url,
      "title" => reference.title,
      "description" => reference.description,
      "site_name" => reference.site_name,
      "favicon_url" => reference.favicon_url,
      "position" => reference.position,
      "metadata" => reference.metadata || %{}
    }
  end

  def asset(%Asset{} = asset, %Note{} = note) do
    storage_file = loaded_storage_file(asset)

    base = %{
      id: asset.id,
      note_id: asset.note_id,
      storage_file_id: asset.storage_file_id,
      role: asset.role,
      caption: asset.caption,
      alt_text: asset.alt_text,
      position: asset.position,
      metadata: asset.metadata || %{},
      storage_file: storage_file(storage_file)
    }

    case public_file_url(asset, note, storage_file) do
      nil -> base
      url -> Map.put(base, :url, url)
    end
  end

  def asset_json(%Asset{} = asset, %Note{} = note) do
    asset(asset, note)
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Map.new()
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
    %{
      id: file.id,
      filename: file.filename,
      content_type: file.content_type,
      size: file.size,
      metadata: file.metadata || %{},
      status: file.status
    }
  end

  defp storage_file(_file), do: nil

  defp public_file_url(_asset, %Note{}, %StorageFile{} = file) do
    if get_in(file.metadata || %{}, ["visibility"]) == "public" do
      "/files/#{file.id}"
    end
  end

  defp public_file_url(_asset, _note, _file), do: nil

  defp loaded_storage_file(%Asset{storage_file: %StorageFile{} = file}), do: file
  defp loaded_storage_file(_asset), do: nil

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
