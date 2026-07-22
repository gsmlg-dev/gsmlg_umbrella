defmodule GSMLG.ProxyRules.Persistence do
  @moduledoc false

  alias GSMLG.ProxyRules.{Diagnostic, Output, Snapshot}

  @artifact_file "artifact.snapshot"
  @transaction_file ".artifact.snapshot.transaction"
  @backup_file ".artifact.snapshot.backup"
  @artifact_type :artifact_snapshot
  @version 1
  @max_marker_bytes 1_024
  @max_envelope_bytes 64 * 1024 * 1024
  @max_output_bytes 64 * 1024 * 1024
  @max_diagnostic_count 1_000
  @max_diagnostic_sample_bytes 512
  @snapshot_keys [
    :__struct__,
    :generation,
    :compiled_at,
    :readiness,
    :source_versions,
    :rendered_outputs,
    :statistics,
    :diagnostics,
    :last_error
  ]
  @output_keys [
    :__struct__,
    :body,
    :sha256,
    :etag,
    :last_modified,
    :content_type,
    :content_length
  ]
  @diagnostic_keys [:__struct__, :kind, :source, :location, :reason, :sample]

  @type read_error ::
          :snapshot_not_found
          | :snapshot_unreadable
          | :corrupt_snapshot
          | :incompatible_snapshot
          | :checksum_mismatch
          | :invalid_snapshot

  @spec write_artifact(binary(), Snapshot.t()) ::
          :ok | {:error, :invalid_snapshot | :persistence_failed}
  def write_artifact(directory, snapshot), do: write_artifact(directory, snapshot, [])

  @spec write_artifact(binary(), Snapshot.t(), keyword()) ::
          :ok | {:error, :invalid_snapshot | :persistence_failed}
  def write_artifact(directory, %Snapshot{} = snapshot, opts)
      when is_binary(directory) and is_list(opts) do
    if valid_snapshot?(snapshot) do
      payload = :erlang.term_to_binary(snapshot)

      envelope =
        :erlang.term_to_binary(%{
          type: @artifact_type,
          version: @version,
          sha256: :crypto.hash(:sha256, payload),
          payload: payload
        })

      if byte_size(envelope) <= @max_envelope_bytes,
        do: atomic_write(Path.join(directory, @artifact_file), envelope, opts),
        else: {:error, :invalid_snapshot}
    else
      {:error, :invalid_snapshot}
    end
  end

  def write_artifact(_directory, _snapshot, _opts), do: {:error, :invalid_snapshot}

  @spec read_artifact(binary()) :: {:ok, Snapshot.t()} | {:error, read_error()}
  def read_artifact(directory), do: read_artifact(directory, [])

  @spec read_artifact(binary(), keyword()) :: {:ok, Snapshot.t()} | {:error, read_error()}
  def read_artifact(directory, opts) when is_binary(directory) and is_list(opts) do
    max_bytes = Keyword.get(opts, :max_envelope_bytes, @max_envelope_bytes)

    case select_authoritative_path(directory) do
      {:ok, path} -> path |> bounded_read(max_bytes) |> decode_file()
      {:error, :snapshot_not_found} = error -> error
    end
  end

  def read_artifact(_directory, _opts), do: {:error, :snapshot_unreadable}

  @spec recover_artifact(binary(), keyword()) :: :ok | {:error, :persistence_failed}
  def recover_artifact(directory, opts \\ [])

  def recover_artifact(directory, opts) when is_binary(directory) and is_list(opts) do
    case recover_transaction(directory, opts) do
      :ok -> :ok
      {:error, _reason} -> {:error, :persistence_failed}
    end
  end

  def recover_artifact(_directory, _opts), do: {:error, :persistence_failed}

  @spec max_output_bytes() :: pos_integer()
  def max_output_bytes, do: @max_output_bytes

  @spec max_diagnostic_count() :: pos_integer()
  def max_diagnostic_count, do: @max_diagnostic_count

  @spec valid_snapshot?(term()) :: boolean()
  def valid_snapshot?(%Snapshot{} = snapshot) do
    exact_keys?(snapshot, @snapshot_keys) and
      non_negative_integer?(snapshot.generation) and
      valid_datetime?(snapshot.compiled_at) and
      Snapshot.persisted_readiness?(snapshot.readiness) and
      valid_source_versions?(snapshot.source_versions) and
      valid_rendered_outputs?(snapshot.rendered_outputs) and
      valid_statistics?(snapshot.statistics) and
      valid_diagnostics?(snapshot.diagnostics) and
      Snapshot.valid_last_error?(snapshot.last_error)
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
  defp decode_file({:error, :file_too_large}), do: {:error, :invalid_snapshot}
  defp decode_file({:error, _reason}), do: {:error, :snapshot_unreadable}

  defp safe_decode(<<131, 80, _compressed::binary>>), do: {:error, :corrupt_snapshot}

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

  defp bounded_read(_path, max_bytes) when not is_integer(max_bytes) or max_bytes <= 0,
    do: {:error, :file_too_large}

  defp bounded_read(path, max_bytes) do
    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} ->
        result =
          case :file.read(file, max_bytes + 1) do
            {:ok, binary} when byte_size(binary) <= max_bytes -> {:ok, binary}
            {:ok, _binary} -> {:error, :file_too_large}
            :eof -> {:ok, <<>>}
            {:error, reason} -> {:error, reason}
          end

        _ = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp atomic_write(path, binary, opts) do
    directory = Path.dirname(path)
    temporary = temporary_path(path)

    result =
      with :ok <- File.mkdir_p(directory),
           :ok <- prepare_for_write(directory, opts),
           {:ok, file} <- :file.open(temporary, [:write, :binary, :exclusive]) do
        write_rename_and_sync(file, temporary, path, binary, directory, opts)
      end

    _ = File.rm(temporary)

    case result do
      :ok -> :ok
      {:error, _reason} -> {:error, :persistence_failed}
    end
  end

  defp write_rename_and_sync(file, temporary, path, binary, directory, opts) do
    result =
      with :ok <- :file.write(file, binary),
           :ok <- :file.sync(file),
           :ok <- :file.close(file),
           :ok <- commit_transaction(temporary, path, directory, opts) do
        :ok
      end

    _ = :file.close(file)
    result
  end

  defp prepare_for_write(directory, _opts), do: transaction_paths_clear?(directory)

  defp transaction_paths_clear?(directory) do
    if File.exists?(transaction_path(directory)) or File.exists?(backup_path(directory)),
      do: {:error, :transaction_pending},
      else: :ok
  end

  defp commit_transaction(temporary, target, directory, opts) do
    marker = transaction_path(directory)
    backup = backup_path(directory)
    had_target? = File.regular?(target)

    with :ok <- preserve_target(target, backup, had_target?),
         :ok <- write_marker(marker, :pending, had_target?, :exclusive),
         :ok <- run_directory_sync(directory, opts),
         :ok <- File.rename(temporary, target),
         :ok <- run_directory_sync(directory, opts),
         :ok <- write_marker(marker, :committed, had_target?, :replace) do
      cleanup_terminal(directory, :committed, had_target?, opts)
      :ok
    end
  end

  defp preserve_target(_target, _backup, false), do: :ok
  defp preserve_target(target, backup, true), do: File.ln(target, backup)

  defp write_marker(path, state, had_target?, mode) do
    marker = :erlang.term_to_binary(%{version: 1, state: state, had_target: had_target?})
    modes = if mode == :exclusive, do: [:write, :binary, :exclusive], else: [:write, :binary]

    case :file.open(path, modes) do
      {:ok, file} ->
        result =
          with :ok <- :file.write(file, marker),
               :ok <- :file.sync(file),
               :ok <- :file.close(file) do
            :ok
          end

        _ = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_authoritative_path(directory) do
    marker = transaction_path(directory)
    backup = backup_path(directory)
    target = Path.join(directory, @artifact_file)

    case bounded_read(marker, @max_marker_bytes) do
      {:error, :enoent} ->
        if File.regular?(backup),
          do: {:ok, backup},
          else: {:ok, target}

      {:ok, binary} ->
        case decode_marker(binary) do
          {:ok, :committed, _had_target?} ->
            {:ok, target}

          {:ok, :pending, had_target?} ->
            select_prior(backup, had_target?)

          {:ok, :rolled_back, true} ->
            {:ok, target}

          {:ok, :rolled_back, false} ->
            {:error, :snapshot_not_found}

          {:error, :invalid_marker} ->
            select_prior(backup, File.regular?(backup))
        end

      {:error, _reason} ->
        select_prior(backup, File.regular?(backup))
    end
  end

  defp select_prior(backup, true), do: {:ok, backup}
  defp select_prior(_backup, false), do: {:error, :snapshot_not_found}

  defp recover_transaction(directory, opts) do
    marker = transaction_path(directory)
    backup = backup_path(directory)
    target = Path.join(directory, @artifact_file)

    case bounded_read(marker, @max_marker_bytes) do
      {:error, :enoent} ->
        if File.regular?(backup),
          do: begin_orphan_rollback(directory, target, backup, marker, opts),
          else: :ok

      {:ok, binary} ->
        case decode_marker(binary) do
          {:ok, state, had_target?} when state in [:committed, :rolled_back] ->
            cleanup_terminal(directory, state, had_target?, opts)

          {:ok, :pending, had_target?} ->
            rollback_pending(directory, target, backup, marker, had_target?, opts)

          {:error, :invalid_marker} ->
            rollback_pending(
              directory,
              target,
              backup,
              marker,
              File.regular?(backup),
              opts
            )
        end

      {:error, _reason} ->
        rollback_pending(
          directory,
          target,
          backup,
          marker,
          File.regular?(backup),
          opts
        )
    end
  end

  defp decode_marker(binary) do
    case safe_decode(binary) do
      {:ok, %{version: 1, state: state, had_target: had_target?} = marker}
      when map_size(marker) == 3 and state in [:pending, :committed, :rolled_back] and
             is_boolean(had_target?) ->
        {:ok, state, had_target?}

      _invalid ->
        {:error, :invalid_marker}
    end
  end

  defp begin_orphan_rollback(directory, target, backup, marker, opts) do
    with :ok <- write_marker(marker, :pending, true, :exclusive),
         :ok <- run_directory_sync(directory, opts) do
      rollback_pending(directory, target, backup, marker, true, opts)
    end
  end

  defp rollback_pending(directory, target, backup, marker, true, opts) do
    recovery = recovery_path(directory)

    result =
      with :ok <- File.ln(backup, recovery),
           :ok <- File.rename(recovery, target),
           :ok <- run_directory_sync(directory, opts),
           :ok <- write_marker(marker, :rolled_back, true, :replace) do
        cleanup_terminal(directory, :rolled_back, true, opts)
      end

    _ = File.rm(recovery)
    result
  end

  defp rollback_pending(directory, target, _backup, marker, false, opts) do
    with :ok <- remove_if_present(target),
         :ok <- run_directory_sync(directory, opts),
         :ok <- write_marker(marker, :rolled_back, false, :replace) do
      cleanup_terminal(directory, :rolled_back, false, opts)
    end
  end

  defp remove_if_present(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_terminal(directory, state, had_target?, opts) do
    backup = backup_path(directory)
    marker = transaction_path(directory)

    backup_clean? =
      case File.rm(backup) do
        :ok -> run_directory_sync(directory, opts) == :ok
        {:error, :enoent} -> true
        {:error, _reason} -> false
      end

    if backup_clean? do
      case File.rm(marker) do
        :ok ->
          if run_directory_sync(directory, opts) != :ok do
            _ = write_marker(marker, state, had_target?, :replace)
          end

        {:error, :enoent} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end

    :ok
  end

  defp run_directory_sync(directory, opts) do
    sync = Keyword.get(opts, :sync_directory, &sync_directory/1)

    try do
      case sync.(directory) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        _unexpected -> {:error, :invalid_sync_result}
      end
    rescue
      _error -> {:error, :directory_sync_failed}
    catch
      _kind, _reason -> {:error, :directory_sync_failed}
    end
  end

  defp sync_directory(directory) do
    case :file.open(String.to_charlist(directory), [:read, :raw, :directory]) do
      {:ok, file} ->
        result = :file.sync(file)
        _ = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp temporary_path(path) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Path.join(Path.dirname(path), ".#{Path.basename(path)}.#{suffix}.tmp")
  end

  defp transaction_path(directory), do: Path.join(directory, @transaction_file)
  defp backup_path(directory), do: Path.join(directory, @backup_file)

  defp recovery_path(directory) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    Path.join(directory, ".artifact.snapshot.#{suffix}.recover")
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
    valid_output_formats?(proxy) and valid_output_formats?(direct) and
      aggregate_output_bytes(outputs) <= @max_output_bytes
  end

  defp valid_rendered_outputs?(_outputs), do: false

  defp valid_output_formats?(%{raw: raw, squid: squid, clash: clash} = formats)
       when map_size(formats) == 3 do
    Enum.all?([raw, squid, clash], &valid_output?/1)
  end

  defp valid_output_formats?(_formats), do: false

  defp aggregate_output_bytes(outputs) do
    for list <- [:proxy, :direct], format <- [:raw, :squid, :clash], reduce: 0 do
      total -> total + outputs[list][format].content_length
    end
  end

  defp valid_output?(%Output{} = output) do
    exact_keys?(output, @output_keys) and
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
    bounded_diagnostics = Enum.take(diagnostics, @max_diagnostic_count + 1)

    length(bounded_diagnostics) <= @max_diagnostic_count and
      Enum.all?(bounded_diagnostics, fn
        %Diagnostic{
          kind: kind,
          source: source,
          location: location,
          reason: reason,
          sample: sample
        } = diagnostic ->
          exact_keys?(diagnostic, @diagnostic_keys) and
            kind in [:invalid, :unsupported, :systemic] and
            source in [:gfwlist, :local_proxy, :local_direct] and
            (location == :system or (is_integer(location) and location > 0)) and
            Diagnostic.valid_reason?(reason) and
            (is_nil(sample) or
               (is_binary(sample) and byte_size(sample) <= @max_diagnostic_sample_bytes))

        _other ->
          false
      end)
  end

  defp valid_diagnostics?(_diagnostics), do: false

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

  defp exact_keys?(map, keys) do
    map_size(map) == length(keys) and Enum.all?(keys, &Map.has_key?(map, &1))
  end
end
