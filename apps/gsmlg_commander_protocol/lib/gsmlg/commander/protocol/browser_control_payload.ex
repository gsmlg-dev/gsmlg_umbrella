defmodule GSMLG.Commander.Protocol.BrowserControlPayload do
  @moduledoc false

  alias GSMLG.Commander.Protocol.Validation

  @profile_operations ~w(profile.status profile.launch profile.stop)
  @workflow_identity ~w(central_job_id remote_execution_id)
  @artifact_job_identity ~w(artifact_id central_job_id remote_execution_id)
  @artifact_session_identity ~w(artifact_id central_session_id remote_session_id)
  @required_output_formats ~w(report.markdown report.json sources.json)
  @output_formats @required_output_formats ++ ~w(report.html screenshot.png)
  @action_types ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download)
  @locator_action_types ~w(click focus fill insert_text select_option wait_for extract download)
  @safe_attributes ~w(aria-controls type)
  @upload_headers ~w(content-type content-length x-content-sha256 x-browser-upload-token)
  @max_artifact_bytes 104_857_600
  @locale ~r/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/
  @video_id ~r/\A[A-Za-z0-9_-]+\z/

  @spec validate(String.t(), pos_integer(), String.t(), map()) ::
          :ok | {:error, GSMLG.Commander.Protocol.Error.t()}
  def validate("browser.control", 1, operation, payload) when is_map(payload) do
    validate_operation(operation, payload)
  end

  def validate(_capability, _version, _operation, _payload), do: :ok

  defp validate_operation(operation, payload) when operation in ~w(manager.status profiles.list),
    do: Validation.fields(payload, [])

  defp validate_operation(operation, payload) when operation in @profile_operations do
    with :ok <- Validation.fields(payload, ["profile_id"]),
         :ok <- Validation.bounded_string(payload["profile_id"], "profile_id", 256) do
      :ok
    end
  end

  defp validate_operation("session.open", payload) do
    with :ok <- session_open_fields(payload),
         :ok <- Validation.uuid(payload["central_session_id"], "central_session_id"),
         :ok <- Validation.bounded_string(payload["profile_id"], "profile_id", 256),
         :ok <- Validation.one_of(payload["mode"], ~w(automation manual), "mode"),
         :ok <- session_operator(payload),
         :ok <- origins(payload["authorized_origins"]),
         :ok <- integer(payload["ttl_ms"], "ttl_ms", 1, 86_400_000),
         :ok <- permissions(Map.get(payload, "permissions", %{})) do
      :ok
    end
  end

  defp validate_operation(operation, payload)
       when operation in ~w(session.observe session.close) do
    session_identity(payload)
  end

  defp validate_operation("session.act", payload) do
    with :ok <- Validation.fields(payload, ~w(session_id action)),
         :ok <- Validation.bounded_string(payload["session_id"], "session_id", 256),
         :ok <- action(payload["action"], payload["session_id"]) do
      :ok
    end
  end

  defp validate_operation("session.manual_acquire", payload) do
    with :ok <- Validation.fields(payload, ~w(session_id operator_id)),
         :ok <- Validation.bounded_string(payload["session_id"], "session_id", 256),
         :ok <- Validation.bounded_string(payload["operator_id"], "operator_id", 256) do
      :ok
    end
  end

  defp validate_operation("session.manual_release", payload) do
    with :ok <- Validation.fields(payload, ~w(session_id lease_id operator_id)),
         :ok <- Validation.bounded_string(payload["session_id"], "session_id", 256),
         :ok <- Validation.bounded_string(payload["lease_id"], "lease_id", 256),
         :ok <- Validation.bounded_string(payload["operator_id"], "operator_id", 256) do
      :ok
    end
  end

  defp validate_operation("workflow.start", payload) do
    with :ok <-
           Validation.fields(
             payload,
             ~w(central_job_id workflow workflow_version profile_id input output_formats requested_by_actor_id)
           ),
         :ok <- Validation.uuid(payload["central_job_id"], "central_job_id"),
         :ok <-
           Validation.one_of(
             payload["workflow"],
             ~w(gemini.deep_research gemini.youtube_analysis),
             "workflow"
           ),
         :ok <- exact_version(payload["workflow_version"]),
         :ok <- Validation.bounded_string(payload["profile_id"], "profile_id", 256),
         :ok <- workflow_input(payload["workflow"], payload["input"]),
         :ok <- output_formats(payload["output_formats"]),
         :ok <-
           Validation.bounded_string(
             payload["requested_by_actor_id"],
             "requested_by_actor_id",
             256
           ) do
      :ok
    end
  end

  defp validate_operation(operation, payload)
       when operation in ~w(workflow.status workflow.cancel) do
    workflow_identity(payload)
  end

  defp validate_operation("workflow.resume", payload) do
    with :ok <- Validation.fields(payload, @workflow_identity ++ ["operator_id"]),
         :ok <- workflow_ids(payload),
         :ok <- Validation.bounded_string(payload["operator_id"], "operator_id", 256) do
      :ok
    end
  end

  defp validate_operation("workflow.reconcile", payload) do
    with :ok <- Validation.fields(payload, ["central_job_id"], ["remote_execution_id"]),
         :ok <- Validation.uuid(payload["central_job_id"], "central_job_id"),
         :ok <- optional_uuid(payload["remote_execution_id"], "remote_execution_id") do
      :ok
    end
  end

  defp validate_operation("artifact.fetch_inline", payload), do: artifact_identity(payload)

  defp validate_operation("artifact.upload", payload) do
    with :ok <-
           artifact_fields(payload, ["upload_url", "required_headers"]),
         :ok <- artifact_ids(payload),
         :ok <- upload_url(payload["upload_url"]),
         :ok <- upload_headers(payload["required_headers"]) do
      :ok
    end
  end

  defp validate_operation("artifact.ack", payload) do
    with :ok <- artifact_fields(payload, ["sha256"]),
         :ok <- artifact_ids(payload),
         :ok <- Validation.sha256(payload["sha256"], "sha256") do
      :ok
    end
  end

  defp validate_operation(_operation, _payload),
    do: Validation.invalid("invalid_operation_payload", %{})

  defp session_open_fields(%{"mode" => "manual"} = payload) do
    Validation.fields(
      payload,
      ~w(central_session_id profile_id mode authorized_origins ttl_ms operator_id),
      ["permissions"]
    )
  end

  defp session_open_fields(payload) do
    Validation.fields(
      payload,
      ~w(central_session_id profile_id mode authorized_origins ttl_ms),
      ["permissions"]
    )
  end

  defp session_operator(%{"mode" => "manual", "operator_id" => operator_id}),
    do: Validation.bounded_string(operator_id, "operator_id", 256)

  defp session_operator(%{"mode" => "automation"}), do: :ok
  defp session_operator(_payload), do: Validation.invalid("invalid_session_operator", %{})

  defp session_identity(payload) do
    with :ok <- Validation.fields(payload, ["session_id"]),
         :ok <- Validation.bounded_string(payload["session_id"], "session_id", 256) do
      :ok
    end
  end

  defp workflow_identity(payload) do
    with :ok <- Validation.fields(payload, @workflow_identity),
         :ok <- workflow_ids(payload) do
      :ok
    end
  end

  defp workflow_ids(payload) do
    with :ok <- Validation.uuid(payload["central_job_id"], "central_job_id"),
         :ok <- Validation.uuid(payload["remote_execution_id"], "remote_execution_id") do
      :ok
    end
  end

  defp artifact_identity(payload) do
    with :ok <- artifact_fields(payload, []),
         :ok <- artifact_ids(payload) do
      :ok
    end
  end

  defp artifact_fields(payload, extra) do
    job_owner? = Enum.any?(~w(central_job_id remote_execution_id), &Map.has_key?(payload, &1))

    session_owner? =
      Enum.any?(~w(central_session_id remote_session_id), &Map.has_key?(payload, &1))

    case {job_owner?, session_owner?} do
      {true, false} -> Validation.fields(payload, @artifact_job_identity ++ extra)
      {false, true} -> Validation.fields(payload, @artifact_session_identity ++ extra)
      _invalid -> Validation.invalid("invalid_artifact_owner", %{})
    end
  end

  defp artifact_ids(%{"central_job_id" => job_id, "remote_execution_id" => remote_id} = payload) do
    with :ok <- Validation.uuid(payload["artifact_id"], "artifact_id"),
         :ok <- Validation.uuid(job_id, "central_job_id"),
         :ok <- Validation.uuid(remote_id, "remote_execution_id") do
      :ok
    end
  end

  defp artifact_ids(
         %{"central_session_id" => session_id, "remote_session_id" => remote_id} = payload
       ) do
    with :ok <- Validation.uuid(payload["artifact_id"], "artifact_id"),
         :ok <- Validation.uuid(session_id, "central_session_id"),
         :ok <- Validation.uuid(remote_id, "remote_session_id") do
      :ok
    end
  end

  defp artifact_ids(_payload), do: Validation.invalid("invalid_artifact_owner", %{})

  defp workflow_input("gemini.deep_research", input) when is_map(input) do
    with :ok <-
           Validation.fields(
             input,
             ~w(prompt output_locale research_scope required_sections auto_approve_plan)
           ),
         :ok <- Validation.bounded_string(input["prompt"], "input.prompt", 65_536),
         :ok <- locale(input["output_locale"]),
         :ok <-
           Validation.bounded_string(input["research_scope"], "input.research_scope", 1_024),
         :ok <- sections(input["required_sections"]),
         :ok <- Validation.boolean(input["auto_approve_plan"], "input.auto_approve_plan") do
      :ok
    end
  end

  defp workflow_input("gemini.youtube_analysis", input) when is_map(input) do
    with :ok <-
           Validation.fields(
             input,
             ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research)
           ),
         :ok <- youtube_url(input["youtube_url"]),
         :ok <-
           Validation.one_of(
             input["analysis_profile"],
             ~w(summary technical_review timeline fact_check action_items),
             "input.analysis_profile"
           ),
         :ok <- locale(input["output_locale"]),
         :ok <- optional_text(input["custom_instructions"], "input.custom_instructions", 8_192),
         :ok <- Validation.boolean(input["use_deep_research"], "input.use_deep_research") do
      :ok
    end
  end

  defp workflow_input(_workflow, _input),
    do: Validation.invalid("invalid_map", %{"field" => "input"})

  defp exact_version(1), do: :ok

  defp exact_version(_version),
    do: Validation.invalid("invalid_value", %{"field" => "workflow_version", "allowed" => [1]})

  defp output_formats(formats) when is_list(formats) do
    cond do
      length(formats) not in 3..5 ->
        Validation.invalid("invalid_list", %{"field" => "output_formats"})

      Enum.uniq(formats) != formats ->
        Validation.invalid("duplicate_value", %{"field" => "output_formats"})

      not Enum.all?(formats, &(&1 in @output_formats)) ->
        Validation.invalid("invalid_value", %{"field" => "output_formats"})

      not Enum.all?(@required_output_formats, &(&1 in formats)) ->
        Validation.invalid("missing_value", %{"field" => "output_formats"})

      true ->
        :ok
    end
  end

  defp output_formats(_formats),
    do: Validation.invalid("invalid_list", %{"field" => "output_formats"})

  defp sections(sections) when is_list(sections) and length(sections) in 1..32 do
    if Enum.uniq(sections) == sections,
      do: each(sections, &Validation.bounded_string(&1, "input.required_sections", 128)),
      else: Validation.invalid("duplicate_value", %{"field" => "input.required_sections"})
  end

  defp sections(_sections),
    do: Validation.invalid("invalid_list", %{"field" => "input.required_sections"})

  defp locale(value) when is_binary(value) and byte_size(value) <= 32 do
    if String.valid?(value) and Regex.match?(@locale, value),
      do: :ok,
      else: Validation.invalid("invalid_locale", %{"field" => "input.output_locale"})
  end

  defp locale(_value),
    do: Validation.invalid("invalid_locale", %{"field" => "input.output_locale"})

  defp youtube_url(value) when is_binary(value) and byte_size(value) <= 2_048 do
    value
    |> URI.parse()
    |> youtube_video_id()
  rescue
    _error -> Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"})
  end

  defp youtube_url(_value),
    do: Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"})

  defp youtube_video_id(%URI{
         scheme: "https",
         host: host,
         port: port,
         path: "/watch",
         userinfo: nil,
         fragment: nil,
         query: query
       })
       when host in ["youtube.com", "www.youtube.com"] and port in [nil, 443] do
    query
    |> decode_query()
    |> Map.get("v")
    |> valid_video_id()
  end

  defp youtube_video_id(%URI{
         scheme: "https",
         host: "youtu.be",
         port: port,
         path: "/" <> video_id,
         userinfo: nil,
         fragment: nil
       })
       when port in [nil, 443] do
    if String.contains?(video_id, "/"),
      do: Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"}),
      else: valid_video_id(video_id)
  end

  defp youtube_video_id(_uri),
    do: Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"})

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    _error -> %{}
  end

  defp valid_video_id(value)
       when is_binary(value) and byte_size(value) in 6..64 do
    if Regex.match?(@video_id, value),
      do: :ok,
      else: Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"})
  end

  defp valid_video_id(_value),
    do: Validation.invalid("invalid_youtube_url", %{"field" => "input.youtube_url"})

  defp action(action, session_id) when is_map(action) do
    with :ok <- action_base(action, session_id),
         :ok <- action_input(action),
         :ok <- action_conditions(action) do
      :ok
    end
  end

  defp action(_action, _session_id),
    do: Validation.invalid("invalid_map", %{"field" => "action"})

  defp action_base(action, session_id) do
    with :ok <- Validation.one_of(action["type"], @action_types, "action.type"),
         :ok <-
           Validation.bounded_string(action["action_id"], "action.action_id", 200),
         :ok <- Validation.bounded_string(action["session_id"], "action.session_id", 256),
         :ok <- matching_session(action["session_id"], session_id),
         :ok <-
           Validation.nonnegative_integer(
             action["expected_revision"],
             "action.expected_revision"
           ),
         :ok <- integer(action["timeout_ms"], "action.timeout_ms", 1, 120_000) do
      :ok
    end
  end

  defp action_input(%{"type" => "navigate"} = action) do
    with :ok <- action_fields(action, ["url"]),
         :ok <- https_url(action["url"], "action.url", 2_048) do
      :ok
    end
  end

  defp action_input(%{"type" => type} = action) when type in @locator_action_types do
    extra =
      case type do
        type when type in ~w(fill insert_text) -> ["locator", "text"]
        "select_option" -> ["locator", "value"]
        _other -> ["locator"]
      end

    with :ok <- action_fields(action, extra),
         :ok <- locator(action["locator"]),
         :ok <- locator_input(type, action) do
      :ok
    end
  end

  defp action_input(%{"type" => "press_key"} = action) do
    with :ok <- action_fields(action, ["key"]),
         :ok <- Validation.bounded_string(action["key"], "action.key", 64) do
      :ok
    end
  end

  defp action_input(%{"type" => "scroll"} = action) do
    with :ok <- action_fields(action, ~w(delta_x delta_y)),
         :ok <- integer(action["delta_x"], "action.delta_x", -100_000, 100_000),
         :ok <- integer(action["delta_y"], "action.delta_y", -100_000, 100_000) do
      :ok
    end
  end

  defp action_input(%{"type" => "screenshot"} = action), do: action_fields(action, [])

  defp action_input(_action), do: Validation.invalid("invalid_action", %{})

  defp action_fields(action, extra) do
    Validation.fields(
      action,
      ~w(action_id session_id expected_revision type timeout_ms) ++ extra,
      ~w(preconditions postconditions postcondition)
    )
  end

  defp locator_input(type, action) when type in ~w(fill insert_text),
    do: optional_text(action["text"], "action.text", 65_536)

  defp locator_input("select_option", action),
    do: Validation.bounded_string(action["value"], "action.value", 1_024)

  defp locator_input(_type, _action), do: :ok

  defp action_conditions(action) do
    cond do
      Map.has_key?(action, "postconditions") and Map.has_key?(action, "postcondition") ->
        Validation.invalid("ambiguous_postcondition", %{})

      true ->
        with :ok <- conditions(Map.get(action, "preconditions", []), "action.preconditions"),
             :ok <- postconditions(action) do
          :ok
        end
    end
  end

  defp postconditions(%{"postconditions" => conditions}),
    do: conditions(conditions, "action.postconditions")

  defp postconditions(%{"postcondition" => condition}), do: condition(condition)
  defp postconditions(_action), do: :ok

  defp conditions(conditions, _field) when is_list(conditions) and length(conditions) <= 8,
    do: each(conditions, &condition/1)

  defp conditions(_conditions, field), do: Validation.invalid("invalid_list", %{"field" => field})

  defp condition(%{"type" => type, "value" => value} = condition)
       when type in ~w(url_is origin_is title_contains) do
    with :ok <- Validation.fields(condition, ~w(type value)),
         :ok <- Validation.bounded_string(value, "condition.value", 2_048) do
      :ok
    end
  end

  defp condition(%{"type" => type, "locator" => target} = condition)
       when type in ~w(node_present node_absent) do
    with :ok <- Validation.fields(condition, ~w(type locator)),
         :ok <- locator(target) do
      :ok
    end
  end

  defp condition(_condition), do: Validation.invalid("invalid_condition", %{})

  defp locator(%{"node_id" => value} = locator) when map_size(locator) == 1,
    do: Validation.bounded_string(value, "locator.node_id", 256)

  defp locator(%{"role" => role} = locator) when map_size(locator) in [1, 2] do
    with :ok <- Validation.fields(locator, ["role"], ["accessible_name"]),
         :ok <- Validation.bounded_string(role, "locator.role", 128),
         :ok <- optional_bounded(locator["accessible_name"], "locator.accessible_name", 512) do
      :ok
    end
  end

  defp locator(%{"attribute" => attribute} = locator)
       when map_size(locator) == 1 and is_map(attribute) do
    with :ok <- Validation.fields(attribute, ~w(name value)),
         :ok <- Validation.one_of(attribute["name"], @safe_attributes, "locator.attribute.name"),
         :ok <- Validation.bounded_string(attribute["value"], "locator.attribute.value", 512) do
      :ok
    end
  end

  defp locator(locator) when is_map(locator) and map_size(locator) == 1 do
    case Map.to_list(locator) do
      [{key, value}] when key in ~w(label placeholder text) ->
        Validation.bounded_string(value, "locator.#{key}", 512)

      [{"css", value}] ->
        Validation.bounded_string(value, "locator.css", 1_024)

      _other ->
        Validation.invalid("invalid_locator", %{})
    end
  end

  defp locator(_locator), do: Validation.invalid("invalid_locator", %{})

  defp permissions(permissions) when is_map(permissions) do
    with :ok <- Validation.fields(permissions, [], ~w(screenshot download)),
         :ok <- each(permissions, fn {key, value} -> Validation.boolean(value, key) end) do
      :ok
    end
  end

  defp permissions(_permissions),
    do: Validation.invalid("invalid_map", %{"field" => "permissions"})

  defp origins(values) when is_list(values) and length(values) in 1..16 do
    cond do
      Enum.uniq(values) != values ->
        Validation.invalid("duplicate_value", %{"field" => "authorized_origins"})

      true ->
        each(values, &origin/1)
    end
  end

  defp origins(_values),
    do: Validation.invalid("invalid_list", %{"field" => "authorized_origins"})

  defp origin(value) when is_binary(value) and byte_size(value) <= 2_048 do
    case URI.parse(value) do
      %URI{
        scheme: "https",
        host: host,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and path in [nil, ""] ->
        :ok

      _invalid ->
        Validation.invalid("invalid_origin", %{"field" => "authorized_origins"})
    end
  end

  defp origin(_value),
    do: Validation.invalid("invalid_origin", %{"field" => "authorized_origins"})

  defp upload_url(value) when is_binary(value) and byte_size(value) in 1..8_192 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, fragment: nil, query: nil}
      when is_binary(host) and host != "" ->
        :ok

      _invalid ->
        Validation.invalid("invalid_url", %{"field" => "upload_url"})
    end
  end

  defp upload_url(_value), do: Validation.invalid("invalid_url", %{"field" => "upload_url"})

  defp https_url(value, field, max_bytes)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= max_bytes do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil}
      when is_binary(host) and host != "" ->
        :ok

      _invalid ->
        Validation.invalid("invalid_url", %{"field" => field})
    end
  end

  defp https_url(_value, field, _max_bytes),
    do: Validation.invalid("invalid_url", %{"field" => field})

  defp upload_headers(headers) when is_map(headers) do
    with :ok <- Validation.fields(headers, @upload_headers),
         :ok <- safe_header(headers["content-type"], "content-type", 255),
         :ok <- content_length(headers["content-length"]),
         :ok <- Validation.sha256(headers["x-content-sha256"], "x-content-sha256"),
         :ok <-
           safe_header(headers["x-browser-upload-token"], "x-browser-upload-token", 512) do
      :ok
    end
  end

  defp upload_headers(_headers),
    do: Validation.invalid("invalid_map", %{"field" => "required_headers"})

  defp safe_header(value, field, max_bytes) when is_binary(value) do
    if byte_size(value) in 1..max_bytes and String.valid?(value) and
         not String.contains?(value, ["\r", "\n", <<0>>]),
       do: :ok,
       else: Validation.invalid("invalid_header", %{"field" => field})
  end

  defp safe_header(_value, field, _max_bytes),
    do: Validation.invalid("invalid_header", %{"field" => field})

  defp content_length(value) when is_binary(value) and byte_size(value) <= 9 do
    case Integer.parse(value) do
      {number, ""} when number in 0..@max_artifact_bytes ->
        if Integer.to_string(number) == value,
          do: :ok,
          else: Validation.invalid("invalid_header", %{"field" => "content-length"})

      _invalid ->
        Validation.invalid("invalid_header", %{"field" => "content-length"})
    end
  end

  defp content_length(_value),
    do: Validation.invalid("invalid_header", %{"field" => "content-length"})

  defp matching_session(session_id, session_id), do: :ok

  defp matching_session(_action_session_id, _request_session_id),
    do: Validation.invalid("session_mismatch", %{})

  defp optional_uuid(nil, _field), do: :ok
  defp optional_uuid(value, field), do: Validation.uuid(value, field)

  defp optional_bounded(nil, _field, _max_bytes), do: :ok

  defp optional_bounded(value, field, max_bytes),
    do: Validation.bounded_string(value, field, max_bytes)

  defp optional_text(value, field, max_bytes)
       when is_binary(value) and byte_size(value) <= max_bytes do
    if String.valid?(value),
      do: :ok,
      else: Validation.invalid("invalid_utf8", %{"field" => field})
  end

  defp optional_text(_value, field, _max_bytes),
    do: Validation.invalid("invalid_string", %{"field" => field})

  defp integer(value, _field, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: :ok

  defp integer(_value, field, min, max),
    do: Validation.invalid("invalid_integer", %{"field" => field, "min" => min, "max" => max})

  defp each(enumerable, validator) do
    Enum.reduce_while(enumerable, :ok, fn value, :ok ->
      case validator.(value) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end
end
