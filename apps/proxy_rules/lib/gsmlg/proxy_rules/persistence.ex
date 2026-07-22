defmodule GSMLG.ProxyRules.Persistence do
  @moduledoc false

  alias GSMLG.ProxyRules.{Diagnostic, Output, Snapshot}

  @artifact_file "artifact.snapshot"
  @artifact_type :artifact_snapshot
  @version 1
  @diagnostic_reasons [
    :invalid_value,
    :empty_domain,
    :invalid_url,
    :unsupported_scheme,
    :invalid_idna,
    :ip_literal,
    :domain_too_long,
    :empty_label,
    :label_too_long,
    :invalid_label,
    :invalid_base64,
    :invalid_utf8,
    :path_specific,
    :regular_expression,
    :modifier,
    :wildcard,
    :ambiguous_rule,
    :systemic_failure
  ]
  @operational_kinds [:remote, :local_proxy, :local_direct, :compiler, :persistence, :store]
  @operational_reasons @diagnostic_reasons ++
                         [
                           :snapshot_not_found,
                           :snapshot_unreadable,
                           :corrupt_snapshot,
                           :incompatible_snapshot,
                           :checksum_mismatch,
                           :invalid_snapshot,
                           :persistence_failed,
                           :configuration_unavailable,
                           :timeout,
                           :connection_failed,
                           :http_error,
                           :body_too_large,
                           :compile_failed,
                           :source_unavailable,
                           :watcher_failed,
                           :read_failed,
                           :not_found,
                           :permission_denied
                         ]

  @type read_error ::
          :snapshot_not_found
          | :snapshot_unreadable
          | :corrupt_snapshot
          | :incompatible_snapshot
          | :checksum_mismatch
          | :invalid_snapshot

  @spec write_artifact(binary(), Snapshot.t()) ::
          :ok | {:error, :invalid_snapshot | :persistence_failed}
  def write_artifact(directory, %Snapshot{} = snapshot) when is_binary(directory) do
    if valid_snapshot?(snapshot) do
      payload = :erlang.term_to_binary(snapshot, [:compressed])

      envelope =
        :erlang.term_to_binary(%{
          type: @artifact_type,
          version: @version,
          sha256: :crypto.hash(:sha256, payload),
          payload: payload
        })

      atomic_write(Path.join(directory, @artifact_file), envelope)
    else
      {:error, :invalid_snapshot}
    end
  end

  def write_artifact(_directory, _snapshot), do: {:error, :invalid_snapshot}

  @spec read_artifact(binary()) :: {:ok, Snapshot.t()} | {:error, read_error()}
  def read_artifact(directory) when is_binary(directory) do
    directory
    |> Path.join(@artifact_file)
    |> File.read()
    |> decode_file()
  end

  def read_artifact(_directory), do: {:error, :snapshot_unreadable}

  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(%Snapshot{} = snapshot) do
    non_negative_integer?(snapshot.generation) and
      valid_datetime?(snapshot.compiled_at) and
      snapshot.readiness in [:not_ready, :refreshing, :ready, :stale] and
      valid_source_versions?(snapshot.source_versions) and
      valid_rendered_outputs?(snapshot.rendered_outputs) and
      valid_statistics?(snapshot.statistics) and
      valid_diagnostics?(snapshot.diagnostics) and
      valid_last_error?(snapshot.last_error)
  end

  def valid_snapshot?(_snapshot), do: false

  defp decode_file({:ok, binary}) do
    with {:ok, envelope} <- safe_decode(binary),
         :ok <- validate_envelope(envelope),
         {:ok, snapshot} <- safe_decode(envelope.payload),
         true <- valid_snapshot?(snapshot) do
      {:ok, snapshot}
    else
      false -> {:error, :invalid_snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_file({:error, :enoent}), do: {:error, :snapshot_not_found}
  defp decode_file({:error, _reason}), do: {:error, :snapshot_unreadable}

  defp safe_decode(binary) when is_binary(binary) do
    {:ok, :erlang.binary_to_term(binary, [:safe])}
  rescue
    ArgumentError -> {:error, :corrupt_snapshot}
  end

  defp safe_decode(_binary), do: {:error, :corrupt_snapshot}

  defp validate_envelope(
         %{type: @artifact_type, version: @version, sha256: hash, payload: payload} = envelope
       )
       when map_size(envelope) == 4 and is_binary(hash) and byte_size(hash) == 32 and
              is_binary(payload) do
    if :crypto.hash(:sha256, payload) == hash,
      do: :ok,
      else: {:error, :checksum_mismatch}
  end

  defp validate_envelope(%{type: _type, version: _version, sha256: _hash, payload: _payload}),
    do: {:error, :incompatible_snapshot}

  defp validate_envelope(_envelope), do: {:error, :corrupt_snapshot}

  defp atomic_write(path, binary) do
    directory = Path.dirname(path)
    temporary = temporary_path(path)

    result =
      with :ok <- File.mkdir_p(directory),
           {:ok, file} <- :file.open(temporary, [:write, :binary, :exclusive]) do
        write_and_rename(file, temporary, path, binary)
      end

    _ = File.rm(temporary)

    case result do
      :ok -> :ok
      {:error, _reason} -> {:error, :persistence_failed}
    end
  end

  defp write_and_rename(file, temporary, path, binary) do
    result =
      with :ok <- :file.write(file, binary),
           :ok <- :file.sync(file),
           :ok <- :file.close(file),
           :ok <- File.rename(temporary, path) do
        :ok
      end

    _ = :file.close(file)
    result
  end

  defp temporary_path(path) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp valid_source_versions?(versions) when is_map(versions) and map_size(versions) == 3 do
    Enum.all?([:gfwlist, :local_proxy, :local_direct], fn key ->
      case Map.fetch(versions, key) do
        {:ok, hash} -> valid_hex_hash?(hash)
        :error -> false
      end
    end)
  end

  defp valid_source_versions?(_versions), do: false

  defp valid_rendered_outputs?(%{proxy: proxy, direct: direct} = outputs)
       when map_size(outputs) == 2 do
    valid_output_formats?(proxy) and valid_output_formats?(direct)
  end

  defp valid_rendered_outputs?(_outputs), do: false

  defp valid_output_formats?(%{raw: raw, squid: squid, clash: clash} = formats)
       when map_size(formats) == 3 do
    Enum.all?([raw, squid, clash], &valid_output?/1)
  end

  defp valid_output_formats?(_formats), do: false

  defp valid_output?(%Output{} = output) do
    is_binary(output.body) and
      valid_hex_hash?(output.sha256) and
      output.sha256 == sha256_hex(output.body) and
      output.etag == ~s("sha256-#{output.sha256}") and
      valid_datetime?(output.last_modified) and
      output.content_type == "text/plain; charset=utf-8" and
      output.content_length == byte_size(output.body)
  end

  defp valid_output?(_output), do: false

  defp valid_statistics?(statistics) when is_map(statistics) and map_size(statistics) == 6 do
    case statistics do
      %{
        sources: sources,
        proxy_rule_count: proxy_count,
        direct_rule_count: direct_count,
        duplicate_count: duplicate_count,
        collapsed_count: collapsed_count,
        conflict_count: conflict_count
      } ->
        valid_source_counts_map?(sources) and
          Enum.all?(
            [proxy_count, direct_count, duplicate_count, collapsed_count, conflict_count],
            &non_negative_integer?/1
          )

      _other ->
        false
    end
  end

  defp valid_statistics?(_statistics), do: false

  defp valid_source_counts_map?(sources) when is_map(sources) and map_size(sources) == 3 do
    Enum.all?([:gfwlist, :local_proxy, :local_direct], fn key ->
      case Map.fetch(sources, key) do
        {:ok, counts} -> valid_counts?(counts)
        :error -> false
      end
    end)
  end

  defp valid_source_counts_map?(_sources), do: false

  defp valid_counts?(%{accepted: accepted, invalid: invalid, unsupported: unsupported} = counts)
       when map_size(counts) == 3 do
    Enum.all?([accepted, invalid, unsupported], &non_negative_integer?/1)
  end

  defp valid_counts?(_counts), do: false

  defp valid_diagnostics?(diagnostics) when is_list(diagnostics) do
    Enum.all?(diagnostics, fn
      %Diagnostic{kind: kind, source: source, location: location, reason: reason, sample: sample} ->
        kind in [:invalid, :unsupported, :systemic] and
          source in [:gfwlist, :local_proxy, :local_direct] and
          (location == :system or (is_integer(location) and location > 0)) and
          reason in @diagnostic_reasons and
          (is_nil(sample) or is_binary(sample))

      _other ->
        false
    end)
  end

  defp valid_diagnostics?(_diagnostics), do: false

  defp valid_last_error?(nil), do: true

  defp valid_last_error?(%{reason: reason} = error) when map_size(error) == 1,
    do: reason in @diagnostic_reasons

  defp valid_last_error?(%{kind: kind, reason: reason} = error) when map_size(error) == 2,
    do: kind in @operational_kinds and reason in @operational_reasons

  defp valid_last_error?(_error), do: false

  defp valid_datetime?(%DateTime{} = datetime) do
    _unix = DateTime.to_unix(datetime, :microsecond)
    true
  rescue
    _error -> false
  end

  defp valid_datetime?(_datetime), do: false

  defp valid_hex_hash?(hash) when is_binary(hash) and byte_size(hash) == 64,
    do: hash =~ ~r/\A[0-9a-f]{64}\z/

  defp valid_hex_hash?(_hash), do: false

  defp sha256_hex(binary), do: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
end
