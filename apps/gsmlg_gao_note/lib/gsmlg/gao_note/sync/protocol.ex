defmodule GSMLG.GaoNote.Sync.Protocol do
  @moduledoc "Strict wire validation and canonical snapshot hashing for sync v1."
  alias GSMLG.GaoNote.Compat.LabelSelector
  @event_keys ~w(event_id note_id generation control version kind snapshot snapshot_hash)
  @snapshot_keys ~w(title content labels created_at updated_at deleted_at attachments)
  @label_keys ~w(key value description value_type)
  @attachment_keys ~w(id path mime description size_bytes checksum_sha256)
  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  @i64_min -9_223_372_036_854_775_808
  @i64_max 9_223_372_036_854_775_807
  @u64_max 18_446_744_073_709_551_615

  def canonical_json(value), do: value |> canonical() |> IO.iodata_to_binary()
  def snapshot_hash(snapshot), do: sha256(canonical_json(snapshot))
  def sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def ack(event), do: Map.delete(event, "snapshot")

  def compare_hlc(left, right) do
    left = {left["millis"], left["counter"], left["node_id"]}
    right = {right["millis"], right["counter"], right["node_id"]}

    cond do
      left < right -> :lt
      left > right -> :gt
      true -> :eq
    end
  end

  def validate_event(event) do
    if valid_event?(event), do: :ok, else: {:error, :validation_failed}
  end

  def uuid?(value), do: is_binary(value) and Regex.match?(@uuid, value)
  def checksum?(value), do: is_binary(value) and Regex.match?(@sha, value)

  def exact_keys?(value, keys),
    do: is_map(value) and Enum.sort(Map.keys(value)) == Enum.sort(keys)

  defp valid_event?(event) do
    exact_keys?(event, @event_keys) and uuid?(event["event_id"]) and uuid?(event["note_id"]) and
      Enum.all?(~w(generation control version), &hlc?(event[&1])) and
      compare_hlc(event["control"], event["generation"]) != :lt and
      (event["kind"] not in ["detach", "fence"] or
         compare_hlc(event["control"], event["generation"]) == :gt) and
      checksum?(event["snapshot_hash"]) and valid_kind_snapshot?(event)
  end

  defp valid_kind_snapshot?(%{"kind" => "fence", "snapshot" => nil}), do: true

  defp valid_kind_snapshot?(%{"kind" => "purge", "snapshot" => nil} = event),
    do: event["snapshot_hash"] == snapshot_hash(nil)

  defp valid_kind_snapshot?(%{"kind" => kind, "snapshot" => snapshot} = event)
       when kind in ["attach", "snapshot", "detach"] do
    snapshot?(snapshot) and event["snapshot_hash"] == snapshot_hash(snapshot)
  end

  defp valid_kind_snapshot?(_), do: false

  defp hlc?(value) do
    exact_keys?(value, ~w(millis counter node_id)) and i64?(value["millis"]) and
      value["millis"] >= 0 and
      uint?(value["counter"]) and uuid?(value["node_id"])
  end

  defp snapshot?(value) do
    exact_keys?(value, @snapshot_keys) and text?(value["title"]) and text?(value["content"]) and
      String.trim(value["title"]) != "" and String.trim(value["content"]) != "" and
      i64?(value["created_at"]) and i64?(value["updated_at"]) and
      (is_nil(value["deleted_at"]) or i64?(value["deleted_at"])) and
      ordered_unique?(value["labels"], &{&1["key"], &1["value"]}, &label?/1) and
      unique_field?(value["labels"], "key") and
      ordered_unique?(value["attachments"], &{&1["path"], &1["id"]}, &attachment?/1) and
      unique_field?(value["attachments"], "id") and unique_field?(value["attachments"], "path")
  end

  defp label?(value) do
    exact_keys?(value, @label_keys) and Enum.all?(~w(key value description), &text?(value[&1])) and
      String.trim(value["key"]) != "" and not String.contains?(value["key"], ~w(& = ! < > ^ $ ~)) and
      value["value_type"] in ~w(text number version date datetime time) and
      LabelSelector.valid_value?(value["value_type"], value["value"])
  end

  defp attachment?(value) do
    exact_keys?(value, @attachment_keys) and
      Enum.all?(~w(id path mime description), &text?(value[&1])) and
      String.trim(value["id"]) != "" and String.trim(value["mime"]) != "" and path?(value["path"]) and
      uint?(value["size_bytes"]) and checksum?(value["checksum_sha256"])
  end

  defp path?(path) do
    path != "" and String.trim(path) == path and not String.contains?(path, ["\\", <<0>>]) and
      not Regex.match?(~r/\A[A-Za-z][A-Za-z0-9+.-]*:/, path) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  defp ordered_unique?(items, key, valid) when is_list(items) do
    Enum.all?(items, valid) and Enum.map(items, key) == Enum.sort(Enum.uniq(Enum.map(items, key)))
  end

  defp ordered_unique?(_, _, _), do: false
  defp unique_field?(items, field), do: length(items) == length(Enum.uniq_by(items, & &1[field]))

  defp text?(value),
    do: is_binary(value) and String.valid?(value) and not String.contains?(value, <<0>>)

  defp i64?(value), do: is_integer(value) and value >= @i64_min and value <= @i64_max
  defp uint?(value), do: is_integer(value) and value >= 0 and value <= @u64_max

  defp canonical(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} -> [Jason.encode!(key, escape: :json), ":", canonical(item)] end)

    ["{", Enum.intersperse(entries, ","), "}"]
  end

  defp canonical(value) when is_list(value),
    do: ["[", value |> Enum.map(&canonical/1) |> Enum.intersperse(","), "]"]

  defp canonical(value) when is_binary(value) or is_integer(value) or is_nil(value),
    do: Jason.encode!(value, escape: :json)
end
