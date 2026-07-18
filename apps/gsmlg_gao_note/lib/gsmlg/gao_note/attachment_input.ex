defmodule GSMLG.GaoNote.AttachmentInput do
  @moduledoc """
  Validated, non-persisted input for a GaoNote attachment.

  Attachment bytes and LiveView uploads are retained only for aggregate
  reconciliation and are excluded from JSON serialization.
  """

  import Ecto.Changeset

  alias GSMLG.GaoNote.Attachment

  @derive {Jason.Encoder, only: [:id, :path, :mime, :description]}
  defstruct [:id, :path, :mime, :description, :bytes, :upload]

  @type upload :: Plug.Upload.t() | {String.t(), binary()}
  @type t :: %__MODULE__{
          id: String.t() | nil,
          path: String.t() | nil,
          mime: String.t() | nil,
          description: String.t() | nil,
          bytes: binary() | nil,
          upload: upload() | nil
        }

  @input_keys [
    {"id", :id},
    {"path", :path},
    {"mime", :mime},
    {"description", :description},
    {"content", :content},
    {"content_base64", :content_base64},
    {"upload", :upload}
  ]
  @cast_fields [:id, :path, :mime, :description, :content, :content_base64]
  @result_fields [:id, :path, :mime, :description, :bytes]
  @types %{
    id: :string,
    path: :string,
    mime: :string,
    description: :string,
    content: :string,
    content_base64: :string,
    bytes: :binary
  }

  @spec cast(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def cast(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)
    upload = Map.get(attrs, :upload)

    changeset =
      {%{}, @types}
      |> Ecto.Changeset.cast(Map.drop(attrs, [:upload]), @cast_fields, empty_values: [])
      |> put_default_description()
      |> validate_text_fields()
      |> trim_change(:id)
      |> trim_change(:mime)
      |> validate_input_required()
      |> normalize_path_change()
      |> decode_content()
      |> validate_upload(upload)

    case apply_action(changeset, :insert) do
      {:ok, values} ->
        input =
          values
          |> Map.take(@result_fields)
          |> Map.put(:upload, upload)
          |> then(&struct!(__MODULE__, &1))

        {:ok, input}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def cast(_attrs) do
    changeset =
      {%{}, @types}
      |> Ecto.Changeset.cast(%{}, @cast_fields)
      |> add_error(:base, "must be a map")

    {:error, %{changeset | action: :insert}}
  end

  defp normalize_keys(attrs) do
    Enum.reduce(@input_keys, %{}, fn {string_key, atom_key}, normalized ->
      cond do
        Map.has_key?(attrs, atom_key) ->
          Map.put(normalized, atom_key, Map.fetch!(attrs, atom_key))

        Map.has_key?(attrs, string_key) ->
          Map.put(normalized, atom_key, Map.fetch!(attrs, string_key))

        true ->
          normalized
      end
    end)
  end

  defp trim_change(changeset, field) do
    if Keyword.has_key?(changeset.errors, field) do
      changeset
    else
      update_change(changeset, field, fn
        value when is_binary(value) -> String.trim(value)
        value -> value
      end)
    end
  end

  defp put_default_description(changeset) do
    case get_field(changeset, :description) do
      nil -> put_change(changeset, :description, "")
      _description -> changeset
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

  defp validate_input_required(changeset) do
    Enum.reduce([:id, :path, :mime], changeset, fn field, changeset ->
      cond do
        Keyword.has_key?(changeset.errors, field) ->
          changeset

        present?(get_field(changeset, field)) ->
          changeset

        true ->
          add_error(changeset, field, "can't be blank", validation: :required)
      end
    end)
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp normalize_path_change(changeset) do
    if Keyword.has_key?(changeset.errors, :path) do
      changeset
    else
      case get_field(changeset, :path) do
        path when is_binary(path) ->
          case Attachment.normalize_path(path) do
            {:ok, path} -> put_change(changeset, :path, path)
            {:error, message} -> add_error(changeset, :path, message)
          end

        _path ->
          changeset
      end
    end
  end

  defp decode_content(changeset) do
    if Enum.any?([:content, :content_base64], &Keyword.has_key?(changeset.errors, &1)) do
      changeset
    else
      content = get_field(changeset, :content)
      content_base64 = get_field(changeset, :content_base64)

      case {content, content_base64} do
        {nil, nil} ->
          changeset

        {content, nil} ->
          put_change(changeset, :bytes, content)

        {nil, content_base64} ->
          put_decoded_base64(changeset, content_base64)

        {content, content_base64} ->
          compare_content(changeset, content, content_base64)
      end
    end
  end

  defp put_decoded_base64(changeset, content_base64) do
    case Base.decode64(content_base64) do
      {:ok, bytes} -> put_change(changeset, :bytes, bytes)
      :error -> add_error(changeset, :content_base64, "must be standard padded Base64")
    end
  end

  defp compare_content(changeset, content, content_base64) do
    case Base.decode64(content_base64) do
      {:ok, ^content} ->
        put_change(changeset, :bytes, content)

      {:ok, _different_bytes} ->
        add_error(
          changeset,
          :content_base64,
          "must decode to the same bytes as content"
        )

      :error ->
        add_error(changeset, :content_base64, "must be standard padded Base64")
    end
  end

  defp validate_upload(changeset, nil), do: changeset
  defp validate_upload(changeset, %Plug.Upload{}), do: changeset

  defp validate_upload(changeset, {filename, bytes})
       when is_binary(filename) and is_binary(bytes),
       do: changeset

  defp validate_upload(changeset, _upload) do
    add_error(changeset, :upload, "must be a Plug.Upload or {filename, binary}")
  end

  defp contains_nul?(value), do: :binary.match(value, <<0>>) != :nomatch
end
