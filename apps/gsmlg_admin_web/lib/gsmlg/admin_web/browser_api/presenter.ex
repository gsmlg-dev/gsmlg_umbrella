defmodule GSMLG.AdminWeb.BrowserAPI.Presenter do
  @moduledoc false

  alias GSMLG.Browser.Origin

  @event_string_fields ~w(kind transfer_mode failure_code intervention_reason status reason code)
  @event_integer_fields ~w(attempt sequence)
  @artifact_metadata_fields ~w(width height source_index sequence page_number)
  @node_string_fields ~w(node_id backend_node_id role name value label placeholder)
  @state_fields ~w(checked disabled expanded focused pressed readonly required selected)
  @attribute_fields ~w(data-testid data-test id name aria-label type autocomplete href)
  @sensitive_markers ~w(password passcode secret token otp one-time credit-card cc-number)

  def node(node) do
    metadata = field(node, :metadata)

    node
    |> take(~w(id commander_id enabled default_backend status capabilities limits last_seen_at)a)
    |> Map.update!(:capabilities, &safe_capabilities/1)
    |> Map.update!(:limits, &safe_limits/1)
    |> Map.put(:online, field(node, :online?) == true)
    |> Map.put(
      :manager_status,
      safe_enum(field(metadata, :manager_status), ~w(available degraded))
    )
    |> Map.put(:agent_version, safe_metadata_string(metadata, :agent_version, 128))
    |> Map.put(:browser_version, safe_metadata_string(metadata, :browser_version, 128))
    |> Map.put(:error_code, error_code(field(node, :last_error)))
    |> dates([:last_seen_at])
  end

  def profile(profile) do
    profile
    |> take(
      ~w(id node_id external_id name backend enabled is_default runtime_status automation_status locale timezone screen last_seen_at)a
    )
    |> Map.update!(:locale, &bounded_string(&1, 32))
    |> Map.update!(:timezone, &bounded_string(&1, 128))
    |> Map.update!(:screen, &safe_screen/1)
    |> Map.put(:allowed_origins, safe_profile_origins(field(profile, :policy)))
    |> Map.put(:error_code, error_code(field(profile, :last_error)))
    |> dates([:last_seen_at])
  end

  def session(session) do
    session
    |> take(
      ~w(id node_id profile_id mode status revision last_seen_at expires_at inserted_at updated_at)a
    )
    |> Map.put(:error_code, error_code(field(session, :error)))
    |> dates(~w(last_seen_at expires_at inserted_at updated_at)a)
  end

  def job(job) do
    job
    |> take(
      ~w(id node_id profile_id session_id workflow workflow_version status phase output_formats attempt previous_job_id last_remote_sequence deadline_at started_at completed_at inserted_at updated_at)a
    )
    |> Map.put(:result, safe_result_manifest(field(job, :result)))
    |> Map.put(:result_available, is_map(field(job, :result)))
    |> Map.put(:error_code, error_code(field(job, :error)))
    |> dates(~w(deadline_at started_at completed_at inserted_at updated_at)a)
  end

  def event(event) do
    event
    |> take(~w(id job_id sequence event phase occurred_at inserted_at)a)
    |> Map.put(:metadata, safe_event_metadata(field(event, :metadata)))
    |> dates(~w(occurred_at inserted_at)a)
  end

  def artifact(artifact) do
    artifact
    |> take(
      ~w(id job_id session_id kind mime filename size sha256 transfer_mode status verified_at rejected_at inserted_at)a
    )
    |> drop_nil_artifact_owner()
    |> Map.put(:metadata, safe_artifact_metadata(field(artifact, :metadata)))
    |> dates(~w(verified_at rejected_at inserted_at)a)
  end

  def observation(observation) when is_map(observation) do
    observation = stringify_map(observation)

    %{}
    |> put_safe("revision", nonnegative_integer(observation["revision"]))
    |> put_safe("url", safe_https_url(observation["url"]))
    |> put_safe("origin", safe_https_origin(observation["origin"]))
    |> put_safe("title", bounded_string(observation["title"], 1_024))
    |> put_safe(
      "loading_state",
      safe_enum(observation["loading_state"], ~w(loading interactive complete))
    )
    |> put_safe("page_kind", bounded_string(observation["page_kind"], 128))
    |> Map.put("visible_controls", safe_semantic_nodes(observation["visible_controls"], 512))
    |> Map.put("semantic_tree", safe_semantic_nodes(observation["semantic_tree"], 2_048))
    |> Map.put("alerts", safe_strings(observation["alerts"], 20, 512))
    |> put_safe("focused_element", safe_focused_element(observation["focused_element"]))
    |> put_safe("observed_at", safe_datetime(observation["observed_at"]))
  end

  def observation(_observation), do: %{}

  def action_result(result) when is_map(result) do
    result = stringify_map(result)

    %{}
    |> put_safe("action_id", bounded_string(result["action_id"], 200))
    |> put_safe("revision", nonnegative_integer(result["revision"]))
    |> put_safe(
      "observation",
      if(is_map(result["observation"]), do: observation(result["observation"]))
    )
    |> put_safe("output", safe_action_output(result["output"]))
  end

  def action_result(_result), do: %{}

  def page(items, opts, cursor_fun) do
    limit = Keyword.fetch!(opts, :limit)

    %{
      limit: limit,
      next_after:
        if(length(items) == limit and items != [], do: cursor_fun.(List.last(items)), else: nil)
    }
  end

  defp safe_capabilities(values) when is_list(values) do
    values
    |> Enum.take(16)
    |> Enum.flat_map(fn value ->
      case safe_capability(value) do
        capability when map_size(capability) > 0 -> [capability]
        _invalid -> []
      end
    end)
  end

  defp safe_capabilities(_values), do: []

  defp safe_capability(value) when is_map(value) do
    value = stringify_map(value)

    %{}
    |> put_safe("id", bounded_string(value["id"], 128))
    |> put_safe("version", positive_integer(value["version"]))
    |> put_safe("backend", bounded_string(value["backend"], 128))
    |> Map.put("operations", safe_strings(value["operations"], 64, 128))
    |> Map.put("limits", safe_limits(value["limits"]))
    |> Map.put("workflows", safe_strings(value["workflows"], 32, 256))
  end

  defp safe_capability(_value), do: %{}

  defp safe_limits(value) when is_map(value) do
    value
    |> Enum.take(32)
    |> Enum.reduce(%{}, fn {key, limit}, safe ->
      with key when is_binary(key) <- safe_key(key, 64),
           limit when is_integer(limit) and limit >= 0 <- limit do
        Map.put(safe, key, limit)
      else
        _invalid -> safe
      end
    end)
  end

  defp safe_limits(_value), do: %{}

  defp safe_screen(value) when is_map(value) do
    value = stringify_map(value)

    %{}
    |> put_safe("width", positive_integer(value["width"]))
    |> put_safe("height", positive_integer(value["height"]))
    |> put_safe("device_scale_factor", positive_number(value["device_scale_factor"]))
    |> put_safe("color_depth", positive_integer(value["color_depth"]))
  end

  defp safe_screen(_value), do: %{}

  defp safe_profile_origins(policy) when is_map(policy) do
    policy
    |> field(:allowed_origins)
    |> safe_strings(16, 2_048)
    |> Enum.filter(&Origin.canonical?/1)
    |> Enum.uniq()
  end

  defp safe_profile_origins(_policy), do: []

  defp safe_metadata_string(metadata, key, maximum) when is_map(metadata),
    do: metadata |> field(key) |> bounded_string(maximum)

  defp safe_metadata_string(_metadata, _key, _maximum), do: nil

  defp safe_event_metadata(value) when is_map(value) do
    value = stringify_map(value)

    strings =
      Enum.reduce(@event_string_fields, %{}, fn key, safe ->
        put_safe(safe, key, bounded_string(value[key], 256))
      end)

    strings = put_safe(strings, "artifact_id", safe_uuid(value["artifact_id"]))

    Enum.reduce(@event_integer_fields, strings, fn key, safe ->
      put_safe(safe, key, nonnegative_integer(value[key]))
    end)
  end

  defp safe_event_metadata(_value), do: %{}

  defp safe_artifact_metadata(value) when is_map(value) do
    value = stringify_map(value)

    Enum.reduce(@artifact_metadata_fields, %{}, fn key, safe ->
      put_safe(safe, key, nonnegative_integer(value[key]))
    end)
  end

  defp safe_artifact_metadata(_value), do: %{}

  defp drop_nil_artifact_owner(%{job_id: nil, session_id: session_id} = artifact)
       when is_binary(session_id),
       do: Map.delete(artifact, :job_id)

  defp drop_nil_artifact_owner(%{job_id: job_id, session_id: nil} = artifact)
       when is_binary(job_id),
       do: Map.delete(artifact, :session_id)

  defp drop_nil_artifact_owner(artifact), do: artifact

  defp safe_result_manifest(value) when is_map(value) do
    value = stringify_map(value)

    %{
      "last_sequence" => bounded_counter(value["last_sequence"]),
      "artifact_count" => bounded_counter(value["artifact_count"]),
      "pending_artifact_count" => bounded_counter(value["pending_artifact_count"]),
      "remote_completed" => value["remote_completed"] == true
    }
  end

  defp safe_result_manifest(_value), do: nil

  defp safe_semantic_nodes(values, limit) when is_list(values) do
    values
    |> Enum.take(limit)
    |> Enum.flat_map(fn value ->
      case safe_semantic_node(value) do
        node when map_size(node) > 0 -> [node]
        _invalid -> []
      end
    end)
  end

  defp safe_semantic_nodes(_values, _limit), do: []

  defp safe_semantic_node(value) when is_map(value) do
    value = stringify_map(value)

    node =
      Enum.reduce(@node_string_fields, %{}, fn key, safe ->
        maximum = if key in ~w(node_id backend_node_id role), do: 256, else: 1_024
        put_safe(safe, key, bounded_string(value[key], maximum))
      end)
      |> put_safe("depth", nonnegative_integer(value["depth"]))
      |> Map.put("state", safe_state(value["state"]))
      |> Map.put("bounds", safe_bounds(value["bounds"]))
      |> Map.put("attributes", safe_attributes(value["attributes"]))

    if sensitive_node?(value) and Map.has_key?(node, "value") do
      Map.put(node, "value", "[REDACTED]")
    else
      node
    end
  end

  defp safe_semantic_node(_value), do: %{}

  defp safe_focused_element(value) when is_map(value),
    do: value |> safe_semantic_node() |> Map.delete("value")

  defp safe_focused_element(_value), do: nil

  defp safe_state(value) when is_map(value) do
    value = stringify_map(value)

    Enum.reduce(@state_fields, %{}, fn key, safe ->
      item = value[key]

      cond do
        is_boolean(item) -> Map.put(safe, key, item)
        key in ~w(checked pressed) -> put_safe(safe, key, bounded_string(item, 64))
        true -> safe
      end
    end)
  end

  defp safe_state(_value), do: %{}

  defp safe_bounds(value) when is_map(value) do
    value = stringify_map(value)

    Enum.reduce(~w(x y width height), %{}, fn key, safe ->
      item = value[key]

      if is_number(item) and (key in ~w(x y) or item >= 0),
        do: Map.put(safe, key, item),
        else: safe
    end)
  end

  defp safe_bounds(_value), do: %{}

  defp safe_attributes(value) when is_map(value) do
    value = stringify_map(value)

    Enum.reduce(@attribute_fields, %{}, fn key, safe ->
      maximum =
        if key in ~w(type autocomplete), do: 128, else: if(key == "href", do: 2_048, else: 512)

      item =
        if key == "href",
          do: safe_https_url(value[key]),
          else: bounded_string(value[key], maximum)

      put_safe(safe, key, item)
    end)
  end

  defp safe_attributes(_value), do: %{}

  defp safe_action_output(value) when is_map(value) do
    value = stringify_map(value)

    %{}
    |> put_safe("status", bounded_string(value["status"], 128))
    |> put_safe("value", bounded_string(value["value"], 65_536))
    |> put_safe("values", safe_strings_or_nil(value["values"], 1_024, 65_536))
    |> put_safe("text", bounded_string(value["text"], 65_536))
    |> put_safe("artifact_id", safe_uuid(value["artifact_id"]))
    |> put_safe("kind", bounded_string(value["kind"], 128))
    |> put_safe("mime", bounded_string(value["mime"], 255))
    |> put_safe("filename", bounded_string(value["filename"], 255))
    |> put_safe("size", nonnegative_integer(value["size"]))
    |> put_safe("sha256", safe_sha256(value["sha256"]))
    |> put_safe("selected", if(is_boolean(value["selected"]), do: value["selected"]))
    |> put_safe("artifact", safe_action_artifact(value["artifact"]))
  end

  defp safe_action_output(_value), do: nil

  defp safe_action_artifact(value) when is_map(value) do
    value = stringify_map(value)

    %{}
    |> put_safe("artifact_id", safe_uuid(value["artifact_id"]))
    |> put_safe("kind", bounded_string(value["kind"], 128))
    |> put_safe("mime", bounded_string(value["mime"], 255))
    |> put_safe("filename", bounded_string(value["filename"], 255))
    |> put_safe("size", nonnegative_integer(value["size"]))
    |> put_safe("sha256", safe_sha256(value["sha256"]))
    |> put_safe("status", safe_enum(value["status"], ~w(pending uploading verified rejected)))
  end

  defp safe_action_artifact(_value), do: nil

  defp safe_strings(values, maximum_items, maximum_bytes) when is_list(values) do
    values
    |> Enum.take(maximum_items)
    |> Enum.flat_map(fn value ->
      case bounded_string(value, maximum_bytes) do
        nil -> []
        safe -> [safe]
      end
    end)
  end

  defp safe_strings(_values, _maximum_items, _maximum_bytes), do: []

  defp safe_strings_or_nil(values, maximum_items, maximum_bytes) when is_list(values),
    do: safe_strings(values, maximum_items, maximum_bytes)

  defp safe_strings_or_nil(_values, _maximum_items, _maximum_bytes), do: nil

  defp sensitive_node?(value) do
    attributes = stringify_map(value["attributes"] || %{})

    [value["name"], value["label"], attributes["type"], attributes["autocomplete"]]
    |> Enum.any?(fn
      marker when is_binary(marker) ->
        downcased = String.downcase(marker)
        Enum.any?(@sensitive_markers, &String.contains?(downcased, &1))

      _invalid ->
        false
    end)
  end

  defp take(value, keys), do: Map.new(keys, &{&1, field(value, &1)})

  defp field(%_{} = value, key), do: Map.get(value, key)

  defp field(value, key) when is_map(value),
    do: Map.get(value, key) || Map.get(value, Atom.to_string(key))

  defp field(_value, _key), do: nil

  defp stringify_map(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), nested} end)

  defp error_code(%{"code" => code}), do: bounded_string(code, 128)
  defp error_code(%{code: code}), do: bounded_string(code, 128)
  defp error_code(_error), do: nil

  defp dates(map, keys) do
    Enum.reduce(keys, map, fn key, acc -> Map.update(acc, key, nil, &date/1) end)
  end

  defp date(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp date(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp date(_value), do: nil

  defp safe_datetime(value) when is_binary(value) and byte_size(value) <= 64 do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, _offset} -> value
      _invalid -> nil
    end
  end

  defp safe_datetime(_value), do: nil

  defp safe_https_url(value) do
    with value when is_binary(value) <- bounded_string(value, 2_048),
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" <-
           URI.parse(value) do
      value
    else
      _invalid -> nil
    end
  end

  defp safe_https_origin(value) do
    with value when is_binary(value) <- safe_https_url(value),
         %URI{path: path, query: nil, fragment: nil} when path in [nil, ""] <- URI.parse(value) do
      value
    else
      _invalid -> nil
    end
  end

  defp safe_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      :error -> nil
    end
  end

  defp safe_uuid(_value), do: nil

  defp safe_sha256(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: value
  end

  defp safe_sha256(_value), do: nil

  defp bounded_string(value, maximum)
       when is_binary(value) and byte_size(value) <= maximum,
       do: if(String.valid?(value), do: value)

  defp bounded_string(_value, _maximum), do: nil

  defp safe_key(value, maximum) when is_atom(value), do: safe_key(Atom.to_string(value), maximum)
  defp safe_key(value, maximum), do: bounded_string(value, maximum)

  defp safe_enum(value, allowed), do: if(value in allowed, do: value)
  defp nonnegative_integer(value) when is_integer(value) and value >= 0, do: value
  defp nonnegative_integer(_value), do: nil

  defp bounded_counter(value) when is_integer(value) and value >= 0,
    do: min(value, 1_000_000_000)

  defp bounded_counter(_value), do: 0
  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil
  defp positive_number(value) when is_number(value) and value > 0, do: value
  defp positive_number(_value), do: nil

  defp put_safe(map, _key, nil), do: map
  defp put_safe(map, key, value), do: Map.put(map, key, value)
end
