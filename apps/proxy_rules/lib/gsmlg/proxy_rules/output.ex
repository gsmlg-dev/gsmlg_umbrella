defmodule GSMLG.ProxyRules.Output do
  @moduledoc """
  A pre-rendered artifact body and its exact immutable HTTP metadata.
  """

  @enforce_keys [:body, :sha256, :etag, :last_modified, :content_type, :content_length]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          body: binary(),
          sha256: binary(),
          etag: binary(),
          last_modified: DateTime.t(),
          content_type: binary(),
          content_length: non_neg_integer()
        }

  @spec new(binary(), DateTime.t()) :: t()
  def new(body, %DateTime{} = compiled_at) when is_binary(body) do
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    %__MODULE__{
      body: body,
      sha256: sha256,
      etag: ~s("sha256-#{sha256}"),
      last_modified: DateTime.truncate(compiled_at, :second),
      content_type: "text/plain; charset=utf-8",
      content_length: byte_size(body)
    }
  end
end
