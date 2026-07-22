defmodule GSMLG.ProxyRules.Snapshot do
  @moduledoc """
  One complete, immutable proxy-rules generation.
  """

  alias GSMLG.ProxyRules.{Diagnostic, Output}

  @enforce_keys [
    :generation,
    :compiled_at,
    :readiness,
    :source_versions,
    :rendered_outputs,
    :statistics,
    :diagnostics,
    :last_error
  ]
  defstruct @enforce_keys

  @type readiness :: :not_ready | :refreshing | :ready | :stale
  @type output_formats :: %{
          required(:raw) => Output.t(),
          required(:squid) => Output.t(),
          required(:clash) => Output.t()
        }
  @type rendered_outputs :: %{
          required(:proxy) => output_formats(),
          required(:direct) => output_formats()
        }
  @type source_versions :: %{
          required(:gfwlist) => binary(),
          required(:local_proxy) => binary(),
          required(:local_direct) => binary()
        }
  @type source_counts :: %{
          required(:accepted) => non_neg_integer(),
          required(:invalid) => non_neg_integer(),
          required(:unsupported) => non_neg_integer()
        }
  @type statistics :: %{
          required(:sources) => %{
            required(:gfwlist) => source_counts(),
            required(:local_proxy) => source_counts(),
            required(:local_direct) => source_counts()
          },
          required(:proxy_rule_count) => non_neg_integer(),
          required(:direct_rule_count) => non_neg_integer(),
          required(:duplicate_count) => non_neg_integer(),
          required(:collapsed_count) => non_neg_integer(),
          required(:conflict_count) => non_neg_integer()
        }
  @type last_error :: nil | %{required(:reason) => Diagnostic.reason()}

  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          compiled_at: DateTime.t(),
          readiness: readiness(),
          source_versions: source_versions(),
          rendered_outputs: rendered_outputs(),
          statistics: statistics(),
          diagnostics: [Diagnostic.t()],
          last_error: last_error()
        }

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> omit_bodies()
  end

  defp omit_bodies(%Output{} = output), do: output |> Map.from_struct() |> Map.delete(:body)
  defp omit_bodies(%_{} = struct), do: struct

  defp omit_bodies(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {key, omit_bodies(value)} end)
  end

  defp omit_bodies(list) when is_list(list), do: Enum.map(list, &omit_bodies/1)
  defp omit_bodies(value), do: value
end
