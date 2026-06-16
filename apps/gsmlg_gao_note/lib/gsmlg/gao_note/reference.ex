defmodule GSMLG.GaoNote.Reference do
  use Ecto.Schema
  import Ecto.Changeset

  alias GSMLG.GaoNote.Note

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @tracking_params ~w(
    utm_source
    utm_medium
    utm_campaign
    utm_term
    utm_content
    fbclid
    gclid
    mc_cid
    mc_eid
  )

  schema "gao_note_references" do
    belongs_to(:note, Note)

    field(:url, :string)
    field(:canonical_url, :string)
    field(:title, :string)
    field(:description, :string)
    field(:site_name, :string)
    field(:favicon_url, :string)
    field(:position, :integer, default: 0)
    field(:metadata, :map, default: %{})

    timestamps()
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [
      :note_id,
      :url,
      :canonical_url,
      :title,
      :description,
      :site_name,
      :favicon_url,
      :position,
      :metadata
    ])
    |> validate_required([:note_id, :url])
    |> normalize_urls()
    |> validate_url()
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> unique_constraint([:note_id, :canonical_url])
  end

  def canonicalize(url) when is_binary(url) do
    uri = URI.parse(String.trim(url))

    query =
      uri.query
      |> decode_query()
      |> Enum.reject(fn {key, _value} -> key in @tracking_params end)
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> URI.encode_query()

    normalized = %URI{
      uri
      | scheme: normalize_downcase(uri.scheme),
        host: normalize_downcase(uri.host),
        fragment: nil,
        query: if(query == "", do: nil, else: query)
    }

    URI.to_string(normalized)
  end

  def canonicalize(url), do: url

  defp normalize_urls(changeset) do
    changeset =
      case get_change(changeset, :url) do
        url when is_binary(url) -> put_change(changeset, :url, String.trim(url))
        _ -> changeset
      end

    canonical = get_field(changeset, :canonical_url)

    if is_binary(canonical) and String.trim(canonical) != "" do
      put_change(changeset, :canonical_url, canonicalize(canonical))
    else
      normalize_url_from_original(changeset)
    end
  end

  defp normalize_url_from_original(changeset) do
    case get_field(changeset, :url) do
      url when is_binary(url) ->
        if String.trim(url) != "" do
          put_change(changeset, :canonical_url, canonicalize(url))
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_url(changeset) do
    validate_change(changeset, :url, fn :url, url ->
      uri = URI.parse(url)

      if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != "" do
        []
      else
        [url: "must be an http or https URL"]
      end
    end)
  end

  defp decode_query(nil), do: []
  defp decode_query(""), do: []

  defp decode_query(query) do
    URI.query_decoder(query)
    |> Enum.to_list()
  end

  defp normalize_downcase(nil), do: nil
  defp normalize_downcase(value), do: String.downcase(value)
end
