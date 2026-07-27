defmodule GSMLG.ProxyRules.SourceSnapshot do
  @moduledoc """
  Validated source content and bounded operational metadata.
  """

  @kinds [:remote, :local_proxy, :local_direct]
  @availabilities [:ready, :stale, :missing]

  @enforce_keys [:kind, :content, :content_sha256, :observed_at]
  defstruct [:kind, :content, :content_sha256, :observed_at, metadata: %{}, availability: :ready]

  @type kind :: :remote | :local_proxy | :local_direct
  @type availability :: :ready | :stale | :missing
  @type remote_metadata :: %{
          required(:source_url) => binary(),
          required(:etag) => binary() | nil,
          required(:last_modified) => binary() | nil,
          required(:fetched_at) => DateTime.t()
        }
  @type local_metadata :: %{
          required(:path) => binary(),
          required(:last_success_at) => DateTime.t() | nil
        }
  @type metadata :: remote_metadata() | local_metadata()

  @type t :: %__MODULE__{
          kind: kind(),
          content: binary(),
          content_sha256: binary(),
          observed_at: DateTime.t(),
          metadata: metadata(),
          availability: availability()
        }

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @spec valid_availability?(term()) :: boolean()
  def valid_availability?(availability), do: availability in @availabilities
end
