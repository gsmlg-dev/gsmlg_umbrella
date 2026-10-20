defmodule GSMLG.GaoNote.Sync.StateQuery do
  @moduledoc false
  alias GSMLG.GaoNote.Sync.Protocol

  @descriptor_keys ~w(event_id note_id generation control kind version snapshot_hash)
  @u64_max 18_446_744_073_709_551_615

  def capabilities?(payload),
    do:
      Protocol.exact_keys?(payload, ["capabilities"]) and
        is_list(payload["capabilities"]) and
        Enum.all?(payload["capabilities"], &(&1 in ["state_query_v1", "task_sync_v1"])) and
        length(Enum.uniq(payload["capabilities"])) == length(payload["capabilities"]) and
        ("task_sync_v1" not in payload["capabilities"] or
           "state_query_v1" in payload["capabilities"])

  def descriptor?(value) do
    Protocol.exact_keys?(value, @descriptor_keys) and
      Protocol.uuid?(value["event_id"]) and Protocol.uuid?(value["note_id"]) and
      value["kind"] in ~w(attach snapshot detach fence purge) and
      Enum.all?(~w(generation control version), &hlc?(value[&1])) and
      Protocol.compare_hlc(value["control"], value["generation"]) != :lt and
      (value["kind"] not in ~w(detach fence) or
         Protocol.compare_hlc(value["control"], value["generation"]) == :gt) and
      Protocol.checksum?(value["snapshot_hash"])
  end

  def valid_request?(payload) do
    Protocol.exact_keys?(payload, ~w(query_id items)) and Protocol.uuid?(payload["query_id"]) and
      is_list(payload["items"]) and length(payload["items"]) in 1..32 and
      Enum.all?(payload["items"], &descriptor?/1) and
      unique?(payload["items"], "note_id") and unique?(payload["items"], "event_id")
  end

  def valid_response?(request, response) do
    Protocol.exact_keys?(response, ~w(query_id items)) and
      response["query_id"] == request["query_id"] and is_list(response["items"]) and
      length(response["items"]) == length(request["items"]) and
      Enum.all?(response["items"], &item?/1) and
      Enum.map(response["items"], & &1["requested"]) == request["items"]
  end

  def equal?(descriptor, pending, item) do
    not pending and descriptor["kind"] == "snapshot" and item["association"] == "attached" and
      item["member"] != nil and item["member"]["kind"] in ~w(attach snapshot) and
      Enum.all?(
        ~w(note_id generation control version snapshot_hash),
        &(item["member"][&1] == descriptor[&1])
      ) and
      item["head"] != nil and item["head"]["version"] == descriptor["version"] and
      item["head"]["snapshot_hash"] == descriptor["snapshot_hash"] and
      item["head"]["attachments_available"] == true
  end

  def conflict?(descriptor, item) do
    states = Enum.reject([descriptor, item["member"], item["head"]], &is_nil/1)

    Enum.any?(states, fn left ->
      Enum.any?(states, fn right ->
        left["version"] == right["version"] and left["snapshot_hash"] != right["snapshot_hash"]
      end)
    end)
  end

  defp item?(item) do
    Protocol.exact_keys?(item, ~w(requested association member head)) and
      descriptor?(item["requested"]) and association?(item) and
      (is_nil(item["head"]) or
         (item["association"] == "attached" and head?(item["head"]))) and
      not conflict?(item["requested"], item)
  end

  defp association?(%{"association" => "missing", "member" => nil}), do: true

  defp association?(%{"association" => association, "member" => member} = item)
       when association in ["attached", "detached"] do
    kinds = if association == "attached", do: ~w(attach snapshot purge), else: ~w(detach fence)

    descriptor?(member) and member["note_id"] == item["requested"]["note_id"] and
      member["kind"] in kinds
  end

  defp association?(_item), do: false

  defp head?(head),
    do:
      Protocol.exact_keys?(head, ~w(version snapshot_hash attachments_available)) and
        hlc?(head["version"]) and Protocol.checksum?(head["snapshot_hash"]) and
        head["attachments_available"] in [true, false, nil]

  defp unique?(items, key), do: length(Enum.uniq_by(items, & &1[key])) == length(items)

  defp hlc?(stamp),
    do:
      Protocol.exact_keys?(stamp, ~w(millis counter node_id)) and
        is_integer(stamp["millis"]) and stamp["millis"] >= 0 and
        stamp["millis"] <= 9_223_372_036_854_775_807 and
        is_integer(stamp["counter"]) and stamp["counter"] >= 0 and
        stamp["counter"] <= @u64_max and Protocol.uuid?(stamp["node_id"])
end
