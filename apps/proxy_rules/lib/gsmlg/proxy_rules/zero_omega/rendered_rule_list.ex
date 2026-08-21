defmodule GSMLG.ProxyRules.ZeroOmega.RenderedRuleList do
  @moduledoc """
  Exact deterministic output bytes and their content-derived metadata.
  """

  @enforce_keys [
    :body,
    :content_type,
    :format,
    :revision,
    :checksum,
    :etag,
    :content_length
  ]
  defstruct @enforce_keys

  @type format :: :switchy | :pac

  @type t :: %__MODULE__{
          body: binary(),
          content_type: binary(),
          format: format(),
          revision: binary(),
          checksum: binary(),
          etag: binary(),
          content_length: non_neg_integer()
        }

  @spec new(binary(), binary(), format(), binary()) :: t()
  def new(body, content_type, format, revision)
      when is_binary(body) and is_binary(content_type) and format in [:switchy, :pac] and
             is_binary(revision) do
    checksum = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    %__MODULE__{
      body: body,
      content_type: content_type,
      format: format,
      revision: revision,
      checksum: checksum,
      etag: ~s("sha256-#{checksum}"),
      content_length: byte_size(body)
    }
  end
end
