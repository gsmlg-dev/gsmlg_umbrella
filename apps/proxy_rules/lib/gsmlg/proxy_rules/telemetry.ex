defmodule GSMLG.ProxyRules.Telemetry do
  @moduledoc """
  Bounded telemetry and diagnostic logging for the proxy-rules pipeline.
  """

  alias GSMLG.ProxyRules.Diagnostic

  @prefix [:gsmlg, :proxy_rules]
  @sample_max_bytes 512
  @truncation_marker "...[truncated]"

  @event_suffixes [
    [:remote, :fetch, :start],
    [:remote, :fetch, :stop],
    [:remote, :fetch, :exception],
    [:remote, :fetch, :not_modified],
    [:local, :source, :change],
    [:local, :reconciliation, :failure],
    [:compile, :start],
    [:compile, :stop],
    [:compile, :exception],
    [:compile, :stale_result, :discard],
    [:artifact, :publication],
    [:artifact, :restoration],
    [:status, :change],
    [:api, :artifact, :hit],
    [:api, :artifact, :conditional_hit],
    [:diagnostic, :unsupported, :sample],
    [:diagnostic, :invalid, :sample]
  ]

  @measurement_keys [
    :duration,
    :response_size,
    :artifact_size,
    :input_rule_count,
    :output_rule_count,
    :duplicate_count,
    :collapsed_count,
    :conflict_count,
    :invalid_count,
    :unsupported_count,
    :generation
  ]

  @sources [:gfwlist, :local_proxy, :local_direct]
  @lists [:proxy, :direct]
  @formats [:raw, :squid, :clash]
  @readiness_values [:not_ready, :refreshing, :ready, :stale]
  @failure_categories [
    :timeout,
    :connect_timeout,
    :receive_timeout,
    :connection_failed,
    :transport_error,
    :http_error,
    :unexpected_status,
    :body_too_large,
    :invalid_base64,
    :invalid_utf8,
    :read_failed,
    :not_found,
    :permission_denied,
    :persistence_failed,
    :compile_failed,
    :compile_timeout,
    :task_crash,
    :source_unavailable,
    :watcher_failed
  ]
  @levels [:debug, :info, :warn, :error]
  @sample_categories [:invalid, :unsupported]

  @type emit_error :: :invalid_event | :invalid_measurements | :invalid_metadata
  @type sample_log_error :: :invalid_sample_log

  @spec emit([atom()], map(), map()) :: :ok | {:error, emit_error()}
  def emit(suffix, measurements, metadata) do
    cond do
      suffix not in @event_suffixes ->
        {:error, :invalid_event}

      not valid_measurements?(measurements) ->
        {:error, :invalid_measurements}

      not valid_metadata?(metadata) ->
        {:error, :invalid_metadata}

      true ->
        :telemetry.execute(@prefix ++ suffix, measurements, metadata)
    end
  end

  @spec sample_log(
          :debug | :info | :warn | :error,
          Diagnostic.t(),
          non_neg_integer(),
          non_neg_integer(),
          module()
        ) :: :ok | {:error, sample_log_error()}
  def sample_log(level, diagnostic, sample_index, limit, logger \\ GSMLG.Telemetry)

  def sample_log(level, %Diagnostic{} = diagnostic, sample_index, limit, logger)
      when level in @levels and is_integer(sample_index) and sample_index >= 0 and
             is_integer(limit) and limit >= 0 and is_atom(logger) do
    if valid_diagnostic_sample?(diagnostic) and function_exported?(logger, :log, 3) do
      if sample_index < limit do
        logger.log(level, "proxy rules diagnostic sample",
          metadata: %{
            category: diagnostic.kind,
            source: diagnostic.source,
            location: diagnostic.location,
            sample: bounded_sample(diagnostic.sample)
          }
        )
      else
        :ok
      end
    else
      {:error, :invalid_sample_log}
    end
  end

  def sample_log(_level, _diagnostic, _sample_index, _limit, _logger),
    do: {:error, :invalid_sample_log}

  defp valid_measurements?(measurements) when is_map(measurements) do
    Enum.all?(measurements, fn {key, value} ->
      key in @measurement_keys and is_number(value) and value >= 0
    end)
  end

  defp valid_measurements?(_measurements), do: false

  defp valid_metadata?(metadata) when is_map(metadata) do
    Enum.all?(metadata, fn
      {:source, value} -> value in @sources
      {:list, value} -> value in @lists
      {:format, value} -> value in @formats
      {:status, value} -> is_integer(value) and value >= 100 and value <= 599
      {:failure_category, value} -> value in @failure_categories
      {:readiness, value} -> value in @readiness_values
      {_key, _value} -> false
    end)
  end

  defp valid_metadata?(_metadata), do: false

  defp valid_diagnostic_sample?(%Diagnostic{
         kind: kind,
         source: source,
         location: location,
         sample: sample
       }) do
    kind in @sample_categories and source in @sources and
      (location == :system or (is_integer(location) and location > 0)) and
      (is_nil(sample) or (is_binary(sample) and String.valid?(sample)))
  end

  defp bounded_sample(nil), do: nil
  defp bounded_sample(sample) when byte_size(sample) <= @sample_max_bytes, do: sample

  defp bounded_sample(sample) do
    prefix_size = @sample_max_bytes - byte_size(@truncation_marker)

    sample
    |> binary_part(0, prefix_size)
    |> trim_incomplete_utf8()
    |> Kernel.<>(@truncation_marker)
  end

  defp trim_incomplete_utf8(prefix) do
    if String.valid?(prefix) do
      prefix
    else
      trim_incomplete_utf8(binary_part(prefix, 0, byte_size(prefix) - 1))
    end
  end
end
