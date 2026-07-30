defmodule GSMLG.ProxyRules.SourceSnapshot do
  @moduledoc """
  Validated source content and bounded operational metadata.
  """

  @kinds [:remote, :local_proxy, :local_direct]
  @availabilities [:ready, :stale, :missing]
  @line_checkpoint_interval 256

  @enforce_keys [:kind, :content, :content_sha256, :observed_at]
  defstruct [
    :kind,
    :content,
    :content_sha256,
    :observed_at,
    line_count: 0,
    line_checkpoints: {0},
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
          line_checkpoints: tuple(),
          metadata: metadata(),
          availability: availability()
        }

  @spec count_lines(binary()) :: non_neg_integer()
  def count_lines(content) when is_binary(content), do: content |> line_metadata() |> elem(0)

  @doc false
  @spec line_checkpoint_interval() :: pos_integer()
  def line_checkpoint_interval, do: @line_checkpoint_interval

  @spec line_metadata(binary()) :: {non_neg_integer(), tuple()}
  def line_metadata(""), do: {0, {0}}

  def line_metadata(content) when is_binary(content) do
    line_metadata(content, 0, 0, [0])
  end

  @spec valid_kind?(term()) :: boolean()
  def valid_kind?(kind), do: kind in @kinds

  @spec valid_availability?(term()) :: boolean()
  def valid_availability?(availability), do: availability in @availabilities

  defp line_metadata(content, offset, count, checkpoints) do
    case :binary.match(content, "\n", scope: {offset, byte_size(content) - offset}) do
      {position, 1} ->
        next_offset = position + 1
        count = count + 1

        checkpoints =
          if rem(count, @line_checkpoint_interval) == 0 and
               next_offset < byte_size(content) do
            [next_offset | checkpoints]
          else
            checkpoints
          end

        line_metadata(content, next_offset, count, checkpoints)

      :nomatch ->
        count = if offset < byte_size(content), do: count + 1, else: count
        {count, checkpoints |> Enum.reverse() |> List.to_tuple()}
    end
  end
end
