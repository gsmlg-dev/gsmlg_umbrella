defmodule GSMLG.GaoNote.Attachment do
  @moduledoc """
  Persisted metadata for a storage-backed GaoNote attachment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.Note
  alias GSMLG.Storage.StorageFile

  @primary_key {:id, :string, autogenerate: false}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @url_scheme ~r/^[a-z][a-z0-9+.-]*:/i
  @windows_drive_prefix ~r/^[a-z]:/i

  schema "gao_note_attachments" do
    belongs_to(:note, Note)
    belongs_to(:storage_file, StorageFile)

    field(:path, :string)
    field(:mime, :string)
    field(:description, :string, default: "")

    timestamps()
  end

  @doc """
  Canonicalizes a path relative to its note.

  Empty segments and `.` segments are removed. Absolute paths, URL schemes,
  Windows drive prefixes, and `..` traversal segments are rejected.
  """
  @spec normalize_path(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_path(path) when is_binary(path) do
    cond do
      not String.valid?(path) ->
        {:error, "must be valid UTF-8"}

      contains_nul?(path) ->
        {:error, "must not contain NUL bytes"}

      true ->
        do_normalize_path(path)
    end
  end

  def normalize_path(_path), do: {:error, "must be a string"}

  defp do_normalize_path(path) do
    path =
      path
      |> String.trim()
      |> String.replace("\\", "/")

    cond do
      path == "" ->
        {:error, "can't be blank"}

      String.starts_with?(path, "/") ->
        {:error, "must be relative to the note"}

      true ->
        normalize_path_segments(String.split(path, "/", trim: false))
    end
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:id, :note_id, :storage_file_id, :path, :mime, :description],
      empty_values: []
    )
    |> put_default_description()
    |> validate_text_fields()
    |> validate_required([:note_id, :storage_file_id])
    |> validate_required_text_fields([:id, :path, :mime])
    |> normalize_path_change()
    |> foreign_key_constraint(:note_id, name: :gao_note_attachments_note_id_fkey)
    |> foreign_key_constraint(:storage_file_id,
      name: :gao_note_attachments_storage_file_id_fkey
    )
    |> unique_constraint(:id, name: :gao_note_attachments_pkey)
    |> unique_constraint(:storage_file_id,
      name: :gao_note_attachments_storage_file_id_index
    )
    |> unique_constraint([:note_id, :path],
      name: :gao_note_attachments_note_id_path_index,
      error_key: :path
    )
  end

  defp normalize_path_segments(segments) do
    if Enum.any?(segments, &(&1 == "..")) do
      {:error, "must not contain a .. segment"}
    else
      segments
      |> Enum.reject(&(&1 in ["", "."]))
      |> Enum.join("/")
      |> validate_canonical_path()
    end
  end

  defp validate_canonical_path(""), do: {:error, "can't be blank"}

  defp validate_canonical_path(path) do
    cond do
      Regex.match?(@windows_drive_prefix, path) ->
        {:error, "must not start with a Windows drive prefix"}

      Regex.match?(@url_scheme, path) ->
        {:error, "must not include a URL scheme"}

      true ->
        {:ok, "./" <> path}
    end
  end

  defp validate_text_fields(changeset) do
    Enum.reduce([:id, :path, :mime, :description], changeset, fn field, changeset ->
      case get_field(changeset, field) do
        value when is_binary(value) ->
          cond do
            not String.valid?(value) ->
              add_error(changeset, field, "must be valid UTF-8")

            contains_nul?(value) ->
              add_error(changeset, field, "must not contain NUL bytes")

            true ->
              changeset
          end

        _value ->
          changeset
      end
    end)
  end

  defp validate_required_text_fields(changeset, fields) do
    Enum.reduce(fields, changeset, fn field, changeset ->
      cond do
        Keyword.has_key?(changeset.errors, field) ->
          changeset

        text_present?(get_field(changeset, field)) ->
          changeset

        true ->
          add_error(changeset, field, "can't be blank", validation: :required)
      end
    end)
  end

  defp text_present?(value) when is_binary(value), do: String.trim(value) != ""
  defp text_present?(_value), do: false

  defp normalize_path_change(changeset) do
    if Keyword.has_key?(changeset.errors, :path) do
      changeset
    else
      case fetch_change(changeset, :path) do
        {:ok, path} ->
          case normalize_path(path) do
            {:ok, path} -> put_change(changeset, :path, path)
            {:error, message} -> add_error(changeset, :path, message)
          end

        :error ->
          changeset
      end
    end
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
    end
  end

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch
end
