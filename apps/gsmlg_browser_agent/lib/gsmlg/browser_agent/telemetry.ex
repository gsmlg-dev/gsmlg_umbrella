defmodule GSMLG.BrowserAgent.Telemetry do
  @moduledoc "Recursive, bounded allowlist for Browser workflow telemetry metadata."

  @leaf_keys ~w(remote_execution_id central_job_id workflow phase status event failure_code intervention_reason duration_ms payload_size content_hash sequence artifact_id kind transfer_mode attempt count)a
  @container_keys ~w(metadata measurements)a
  @max_depth 3
  @max_entries 32
  @max_string_bytes 256
  @max_list_items 16
  @max_encoded_bytes 4_096

  @workflow_transition [:gsmlg, :browser, :workflow, :transition]
  @intervention_required [:gsmlg, :browser, :intervention, :required]

  def workflow_transition(checkpoint, duration_ms, opts \\ [])

  def workflow_transition(checkpoint, duration_ms, opts)
      when is_map(checkpoint) and is_integer(duration_ms) and duration_ms >= 0 do
    metadata =
      checkpoint
      |> workflow_metadata(Keyword.get(opts, :phase, checkpoint.phase))
      |> put_optional(:failure_code, Keyword.get(opts, :failure_code))

    execute(@workflow_transition, %{count: 1, duration_ms: duration_ms}, metadata)
  end

  def workflow_transition(_checkpoint, _duration_ms, _opts), do: :ok

  def intervention_required(checkpoint, reason) when is_map(checkpoint) and is_atom(reason) do
    checkpoint
    |> workflow_metadata(checkpoint.phase)
    |> Map.put(:intervention_reason, Atom.to_string(reason))
    |> then(&execute(@intervention_required, %{count: 1}, &1))
  end

  def intervention_required(_checkpoint, _reason), do: :ok

  def sanitize(metadata) when is_map(metadata) do
    metadata
    |> sanitize_map(0)
    |> fit()
  end

  def sanitize(_metadata), do: %{}

  defp workflow_metadata(checkpoint, phase) do
    %{
      remote_execution_id: checkpoint.remote_execution_id,
      central_job_id: checkpoint.central_job_id,
      workflow: checkpoint.workflow,
      phase: Atom.to_string(phase),
      status: Atom.to_string(checkpoint.status)
    }
  end

  defp put_optional(map, _key, nil), do: map

  defp put_optional(map, key, value) when is_atom(value),
    do: Map.put(map, key, Atom.to_string(value))

  defp put_optional(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp put_optional(map, _key, _value), do: map

  defp execute(event, measurements, metadata) do
    :telemetry.execute(event, sanitize(measurements), sanitize(metadata))
  rescue
    _exception -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp sanitize_map(_map, depth) when depth > @max_depth, do: %{}

  defp sanitize_map(map, depth) do
    map
    |> Enum.take(@max_entries)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized = normalize_key(key)

      cond do
        normalized in @leaf_keys ->
          put_safe(acc, key, sanitize_leaf(value))

        normalized in @container_keys and is_map(value) ->
          Map.put(acc, key, sanitize_map(value, depth + 1))

        true ->
          acc
      end
    end)
  end

  defp sanitize_leaf(value) when is_binary(value), do: truncate(value, @max_string_bytes)

  defp sanitize_leaf(value) when is_integer(value) or is_float(value) or is_boolean(value),
    do: value

  defp sanitize_leaf(value) when is_list(value) do
    value
    |> Enum.take(@max_list_items)
    |> Enum.flat_map(fn
      item when is_binary(item) -> [truncate(item, @max_string_bytes)]
      item when is_number(item) or is_boolean(item) -> [item]
      _unsafe -> []
    end)
  end

  defp sanitize_leaf(_unsafe), do: nil

  defp put_safe(map, _key, nil), do: map
  defp put_safe(map, key, value), do: Map.put(map, key, value)

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    Enum.find(@leaf_keys ++ @container_keys, &(&1 == key))
  end

  defp normalize_key(_key), do: nil

  defp truncate(value, max_bytes) when byte_size(value) <= max_bytes, do: value

  defp truncate(value, max_bytes) do
    value
    |> String.graphemes()
    |> Enum.reduce_while({[], 0}, fn grapheme, {items, size} ->
      next = byte_size(grapheme)

      if size + next <= max_bytes,
        do: {:cont, {[grapheme | items], size + next}},
        else: {:halt, {items, size}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp fit(metadata) do
    if encoded_size(metadata) <= @max_encoded_bytes, do: metadata, else: %{}
  end

  defp encoded_size(value), do: value |> JSON.encode!() |> byte_size()
end
