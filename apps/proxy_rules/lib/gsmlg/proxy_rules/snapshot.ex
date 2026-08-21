defmodule GSMLG.ProxyRules.Snapshot do
  @moduledoc """
  One complete, immutable proxy-rules generation.
  """

  alias GSMLG.ProxyRules.{Diagnostic, Output, Transport}
  alias GSMLG.ProxyRules.ZeroOmega.PublishedPolicy

  @enforce_keys [
    :generation,
    :compiled_at,
    :readiness,
    :source_versions,
    :rendered_outputs,
    :zeroomega_policy,
    :statistics,
    :diagnostics,
    :last_error
  ]
  defstruct @enforce_keys

  @type readiness :: :not_ready | :refreshing | :ready | :stale
  @type persisted_readiness :: :ready | :stale
  @type operational_kind ::
          :remote | :local_proxy | :local_direct | :compiler | :persistence | :store
  @type operational_reason ::
          Diagnostic.reason()
          | Transport.error_reason()
          | :snapshot_not_found
          | :snapshot_unreadable
          | :corrupt_snapshot
          | :incompatible_snapshot
          | :checksum_mismatch
          | :invalid_snapshot
          | :persistence_failed
          | :configuration_unavailable
          | :unexpected_status
          | :no_accepted_rules
          | :compile_failed
          | :compile_timeout
          | :task_crash
          | :source_unavailable
          | :remote_unavailable
          | :local_unavailable
          | :watcher_failed
          | :read_failed
          | :not_found
          | :permission_denied
  @type operational_error :: %{
          required(:kind) => operational_kind(),
          required(:reason) => operational_reason()
        }
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
  @type last_error :: nil | operational_error()

  @type t :: %__MODULE__{
          generation: non_neg_integer(),
          compiled_at: DateTime.t(),
          readiness: readiness(),
          source_versions: source_versions(),
          rendered_outputs: rendered_outputs(),
          zeroomega_policy: PublishedPolicy.t(),
          statistics: statistics(),
          diagnostics: [Diagnostic.t()],
          last_error: last_error()
        }

  @operational_kinds [:remote, :local_proxy, :local_direct, :compiler, :persistence, :store]
  @operational_reasons [
    :snapshot_not_found,
    :snapshot_unreadable,
    :corrupt_snapshot,
    :incompatible_snapshot,
    :checksum_mismatch,
    :invalid_snapshot,
    :persistence_failed,
    :configuration_unavailable,
    :unexpected_status,
    :no_accepted_rules,
    :compile_failed,
    :compile_timeout,
    :task_crash,
    :source_unavailable,
    :remote_unavailable,
    :local_unavailable,
    :watcher_failed,
    :read_failed,
    :not_found,
    :permission_denied
  ]

  @spec persisted_readiness?(term()) :: boolean()
  def persisted_readiness?(readiness), do: readiness in [:ready, :stale]

  @spec valid_operational_error?(term()) :: boolean()
  def valid_operational_error?(%{kind: kind, reason: reason} = error) when map_size(error) == 2,
    do:
      kind in @operational_kinds and
        (reason in @operational_reasons or Diagnostic.valid_reason?(reason) or
           Transport.valid_error_reason?(reason))

  def valid_operational_error?(_error), do: false

  @spec valid_last_error?(term()) :: boolean()
  def valid_last_error?(nil), do: true
  def valid_last_error?(error), do: valid_operational_error?(error)

  @spec metadata(t()) :: map()
  def metadata(%__MODULE__{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.delete(:zeroomega_policy)
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
