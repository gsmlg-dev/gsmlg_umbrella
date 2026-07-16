defmodule GSMLG.GaoNote.Attachment do
  @moduledoc """
  Storage-backed GaoNote attachment.

  `path` is the attachment path relative to the note body. Markdown content should
  reference it with the same relative path, for example `./data.txt`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.Note
  alias GSMLG.Storage.StorageFile

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]
  @roles ~w(attachment cover inline source)
  @url_scheme ~r/^[a-z][a-z0-9+.-]*:/i
  @windows_absolute_path ~r/^[a-z]:[\\\/]/i

  schema "gao_note_attachments" do
    belongs_to(:note, Note)
    belongs_to(:storage_file, StorageFile)

    field(:role, :string, default: "attachment")
    field(:description, :string, default: "")
    field(:path, :string)
    field(:caption, :string)
    field(:alt_text, :string)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def roles, do: @roles

  @doc """
  Returns the attachment-level visibility selected in attachment metadata.

  Attachments without an explicit setting inherit the storage-file visibility.
  Invalid or unavailable visibility data is treated as private.
  """
  def visibility(%__MODULE__{} = attachment) do
    case metadata_visibility(attachment.metadata) do
      nil -> storage_visibility(attachment.storage_file)
      visibility -> visibility
    end
  end

  @doc """
  Returns the effective visibility after applying the storage privacy floor.
  """
  def effective_visibility(%__MODULE__{} = attachment) do
    storage_visibility = storage_visibility(attachment.storage_file)

    case metadata_visibility(attachment.metadata) do
      nil -> storage_visibility
      "private" -> "private"
      "public" when storage_visibility == "public" -> "public"
      _visibility -> "private"
    end
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :note_id,
      :storage_file_id,
      :role,
      :description,
      :path,
      :caption,
      :alt_text,
      :position,
      :metadata
    ])
    |> put_default_description()
    |> normalize_path()
    |> validate_required([:note_id, :storage_file_id])
    |> validate_inclusion(:role, @roles)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_note_relative_path()
    |> unique_constraint([:note_id, :storage_file_id],
      name: :gao_note_attachments_note_id_storage_file_id_index,
      error_key: :storage_file_id
    )
    |> unique_constraint([:note_id, :path],
      name: :gao_note_attachments_note_id_path_index,
      error_key: :path
    )
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end

  defp normalize_path(changeset) do
    case get_change(changeset, :path) do
      path when is_binary(path) ->
        path = String.trim(path)

        cond do
          path == "" -> put_change(changeset, :path, nil)
          String.starts_with?(path, "./") -> put_change(changeset, :path, path)
          absolute_path?(path) -> put_change(changeset, :path, path)
          url_path?(path) -> put_change(changeset, :path, path)
          true -> put_change(changeset, :path, "./#{path}")
        end

      _path ->
        changeset
    end
  end

  defp validate_note_relative_path(changeset) do
    validate_change(changeset, :path, fn :path, path ->
      cond do
        is_nil(path) ->
          []

        absolute_path?(path) ->
          [path: "must be relative to the note, for example ./data.txt"]

        String.contains?(path, "..") ->
          [path: "must not contain .."]

        url_path?(path) ->
          [path: "must not be an absolute URL"]

        not String.starts_with?(path, "./") ->
          [path: "must start with ./"]

        true ->
          []
      end
    end)
  end

  defp absolute_path?(path) do
    Path.type(path) == :absolute or String.starts_with?(path, "\\") or
      Regex.match?(@windows_absolute_path, path)
  end

  defp url_path?(path) do
    Regex.match?(@url_scheme, path) or String.contains?(path, "://")
  end

  defp metadata_visibility(metadata) when is_map(metadata) do
    case Map.fetch(metadata, "visibility") do
      {:ok, visibility} -> normalize_visibility(visibility)
      :error -> metadata |> Map.get(:visibility) |> normalize_optional_visibility()
    end
  end

  defp metadata_visibility(_metadata), do: nil

  defp storage_visibility(%StorageFile{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Map.get("visibility", Map.get(metadata, :visibility))
    |> normalize_visibility()
  end

  defp storage_visibility(_storage_file), do: "private"

  defp normalize_optional_visibility(nil), do: nil
  defp normalize_optional_visibility(visibility), do: normalize_visibility(visibility)

  defp normalize_visibility("public"), do: "public"
  defp normalize_visibility("private"), do: "private"
  defp normalize_visibility(_visibility), do: "private"
end
