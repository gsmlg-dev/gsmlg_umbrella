defmodule GSMLG.ProxyRules.SourceSnapshot do
  @moduledoc """
  Validated source content and bounded operational metadata.
  """

  @kinds [:remote, :local_proxy, :local_direct]
  @availabilities [:ready, :stale, :missing]

  @enforce_keys [:kind, :content, :content_sha256, :observed_at]
  defstruct [
    :kind,
    :content,
    :content_sha256,
    :observed_at,
    line_count: 0,
    metadata: %{},
    availability: :ready
  ]

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
          line_count: non_neg_integer(),
          metadata: metadata(),
          availability: availability()
        }

  @spec count_lines(binary()) :: non_neg_integer()
  def count_lines(""), do: 0
  def count_lines(content) when is_binary(content), do: count_lines(content, 0, 0)

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @spec valid_availability?(term()) :: boolean()
  def valid_availability?(availability), do: availability in @availabilities

  defp count_lines(content, offset, count) do
    case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
      {position, 1} ->
        count_lines(content, position + 1, count + 1)

      :nomatch ->
        if offset < byte_size(content), do: count + 1, else: count
    end
  end
end
