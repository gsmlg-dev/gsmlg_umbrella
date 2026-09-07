defmodule GSMLG.AdminWeb.BrowserAPI.Request do
  @moduledoc false

  alias GSMLG.Browser.Origin

  @job_fields ~w(workflow workflow_version node profile input idempotency_key output_formats)
  @job_required ~w(workflow workflow_version input idempotency_key output_formats)
  @action_fields ~w(action_id expected_revision type locator input postcondition timeout_ms)
  @action_required ~w(action_id expected_revision type input timeout_ms)
  @output_formats ~w(report.markdown report.html report.json sources.json screenshot.png)
  @required_output_formats ~w(report.markdown report.json sources.json)
  @action_types ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download)
  @locator_action_types ~w(click focus fill insert_text select_option wait_for extract download)
  @session_required ~w(node profile mode authorized_origins ttl)
  @session_fields @session_required ++ ["permissions"]

  def pagination(params, cursor_type) when is_map(params) do
    with :ok <- exact_keys(params, ~w(limit after)),
         {:ok, limit} <- integer(Map.get(params, "limit", "50"), 1, 100),
         {:ok, cursor} <- cursor(Map.get(params, "after"), cursor_type) do
      {:ok, [limit: limit, after: cursor]}
    else
      _invalid -> error("invalid_query")
    end
  end

  def job(body) when is_map(body) do
    with :ok <- exact_keys(body, @job_fields),
         :ok <- required_keys(body, @job_required),
         workflow when workflow in ["gemini.deep_research", "gemini.youtube_analysis"] <-
           body["workflow"],
         1 <- body["workflow_version"],
         {:ok, node_id} <- optional_uuid(body["node"]),
         {:ok, profile_id} <- optional_uuid(body["profile"]),
         :ok <- workflow_input(workflow, body["input"]),
         :ok <- bounded_string(body["idempotency_key"], 1, 512),
         :ok <- output_formats(body["output_formats"]) do
      {:ok,
       %{
         workflow: workflow,
         workflow_version: 1,
         node_id: node_id,
         profile_id: profile_id,
         input: body["input"],
         idempotency_key: body["idempotency_key"],
         output_formats: body["output_formats"]
       }}
    else
      _invalid -> error("invalid_request")
    end
  end

  def job(_body), do: error("invalid_request")

  def session(body) when is_map(body) do
    with :ok <- exact_keys(body, @session_fields),
         :ok <- required_keys(body, @session_required),
         {:ok, node_id} <- uuid(body["node"]),
         {:ok, profile_id} <- uuid(body["profile"]),
         mode when mode in ~w(automation manual) <- body["mode"],
         {:ok, origins} <- origins(body["authorized_origins"]),
         {:ok, ttl_ms} <- body_integer(body["ttl"], 1, 86_400_000),
         {:ok, permissions} <- session_permissions(Map.get(body, "permissions", %{})) do
      {:ok,
       %{
         node_id: node_id,
         profile_id: profile_id,
         mode: mode,
         authorized_origins: origins,
         ttl_ms: ttl_ms,
         permissions: permissions
       }}
    else
      _invalid -> error("invalid_request")
    end
  end

  def session(_body), do: error("invalid_request")

  defp session_permissions(permissions) when is_map(permissions) do
    if Map.keys(permissions) -- ~w(screenshot download) == [] and
         Enum.all?(Map.values(permissions), &is_boolean/1),
       do: {:ok, permissions},
       else: error("invalid_request")
  end

  defp session_permissions(_permissions), do: error("invalid_request")

  def profile_configuration(body) when is_map(body) do
    with :ok <- exact_required_keys(body, ~w(enabled is_default allowed_origins)),
         enabled when is_boolean(enabled) <- body["enabled"],
         is_default when is_boolean(is_default) <- body["is_default"],
         false <- is_default and not enabled,
         {:ok, origins} <- origins(body["allowed_origins"]) do
      {:ok, %{enabled: enabled, is_default: is_default, allowed_origins: origins}}
    else
      _invalid -> error("invalid_request")
    end
  end

  def profile_configuration(_body), do: error("invalid_request")

  def action(session_id, body) when is_map(body) do
    with {:ok, _session_id} <- uuid(session_id),
         :ok <- exact_keys(body, @action_fields),
         :ok <- required_keys(body, @action_required),
         :ok <- bounded_string(body["action_id"], 1, 200),
         type when type in @action_types <- body["type"],
         :ok <- revision(body["expected_revision"]),
         :ok <- action_input(type, body["input"], body["locator"]),
         :ok <- postcondition(body["postcondition"]),
         {:ok, timeout} <- body_integer(body["timeout_ms"], 1, 120_000) do
      {:ok,
       %{
         action_id: body["action_id"],
         expected_revision: body["expected_revision"],
         type: type,
         locator: body["locator"],
         input: body["input"],
         postcondition: body["postcondition"],
         timeout_ms: timeout
       }}
    else
      _invalid -> error("invalid_action")
    end
  end

  def action(_session_id, _body), do: error("invalid_action")

  def retry(%{"idempotency_key" => key} = body) do
    with :ok <- exact_keys(body, ["idempotency_key"]),
         :ok <- bounded_string(key, 1, 512) do
      {:ok, %{idempotency_key: key}}
    else
      _invalid -> error("invalid_request")
    end
  end

  def retry(_body), do: error("invalid_request")

  def empty(body) when body == %{}, do: :ok
  def empty(_body), do: error("invalid_request")

  def empty_query(query) when query == %{}, do: :ok
  def empty_query(_query), do: error("invalid_query")

  def id(value) do
    case uuid(value) do
      {:ok, id} -> {:ok, id}
      {:error, _reason} -> error("invalid_request")
    end
  end

  defp workflow_input("gemini.deep_research", input) when is_map(input) do
    with :ok <-
           exact_required_keys(
             input,
             ~w(prompt output_locale research_scope required_sections auto_approve_plan)
           ),
         :ok <- bounded_string(input["prompt"], 1, 65_536),
         :ok <- locale(input["output_locale"]),
         :ok <- bounded_string(input["research_scope"], 1, 1_024),
         true <- is_boolean(input["auto_approve_plan"]),
         sections when is_list(sections) <- input["required_sections"],
         true <- length(sections) in 1..32,
         true <- sections == Enum.uniq(sections),
         true <- Enum.all?(sections, &match?(:ok, bounded_string(&1, 1, 128))) do
      :ok
    else
      _invalid -> error("invalid_request")
    end
  end

  defp workflow_input("gemini.youtube_analysis", input) when is_map(input) do
    with :ok <-
           exact_required_keys(
             input,
             ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research)
           ),
         :ok <- youtube_url(input["youtube_url"]),
         true <-
           input["analysis_profile"] in ~w(summary technical_review timeline fact_check action_items),
         :ok <- locale(input["output_locale"]),
         :ok <- bounded_string(input["custom_instructions"], 0, 8_192),
         true <- is_boolean(input["use_deep_research"]) do
      :ok
    else
      _invalid -> error("invalid_request")
    end
  end

  defp workflow_input(_workflow, _input), do: error("invalid_request")

  defp output_formats(formats) when is_list(formats) do
    if length(formats) in 3..5 and formats == Enum.uniq(formats) and
         Enum.all?(formats, &(&1 in @output_formats)) and
         Enum.all?(@required_output_formats, &(&1 in formats)),
       do: :ok,
       else: error("invalid_request")
  end

  defp output_formats(_formats), do: error("invalid_request")

  defp action_input("navigate", %{"url" => url} = input, nil) do
    with :ok <- exact_keys(input, ["url"]), do: navigation_url(url)
  end

  defp action_input(type, input, locator) when type in @locator_action_types do
    with :ok <- locator(locator), do: locator_action_input(type, input)
  end

  defp action_input("press_key", %{"key" => key} = input, nil) do
    with :ok <- exact_keys(input, ["key"]), do: bounded_string(key, 1, 64)
  end

  defp action_input("scroll", %{"delta_x" => x, "delta_y" => y} = input, nil)
       when is_integer(x) and is_integer(y) and x in -100_000..100_000 and y in -100_000..100_000 do
    exact_keys(input, ~w(delta_x delta_y))
  end

  defp action_input("screenshot", input, nil) do
    exact_keys(input, [])
  end

  defp action_input(_type, _input, _locator), do: error("invalid_action")

  defp locator_action_input(type, input) when type in ~w(click focus wait_for extract download) do
    exact_keys(input, [])
  end

  defp locator_action_input(type, %{"text" => text} = input) when type in ~w(fill insert_text) do
    with :ok <- exact_keys(input, ["text"]), do: bounded_string(text, 0, 65_536)
  end

  defp locator_action_input("select_option", %{"value" => value} = input) do
    with :ok <- exact_keys(input, ["value"]), do: bounded_string(value, 1, 1_024)
  end

  defp locator_action_input(_type, _input), do: error("invalid_action")

  defp locator(%{"node_id" => value} = locator) when map_size(locator) == 1,
    do: bounded_string(value, 1, 256)

  defp locator(%{"role" => role} = locator) when map_size(locator) in [1, 2] do
    with :ok <- exact_keys(locator, ~w(role accessible_name)),
         :ok <- bounded_string(role, 1, 128),
         :ok <- optional_locator_value(locator["accessible_name"]) do
      :ok
    end
  end

  defp locator(%{"attribute" => %{"name" => name, "value" => value}} = locator)
       when map_size(locator) == 1 and name in ~w(aria-controls type),
       do: locator_value(value)

  defp locator(locator) when is_map(locator) and map_size(locator) == 1 do
    case Map.to_list(locator) do
      [{key, value}] when key in ~w(label placeholder text) -> locator_value(value)
      [{"css", value}] -> bounded_string(value, 1, 1_024)
      _other -> error("invalid_action")
    end
  end

  defp locator(_locator), do: error("invalid_action")

  defp postcondition(nil), do: :ok

  defp postcondition(%{"type" => type, "value" => value} = condition)
       when type in ~w(url_is origin_is title_contains) do
    with :ok <- exact_keys(condition, ~w(type value)), do: bounded_string(value, 1, 2_048)
  end

  defp postcondition(%{"type" => type, "locator" => target} = condition)
       when type in ~w(node_present node_absent) do
    with :ok <- exact_keys(condition, ~w(type locator)), do: locator(target)
  end

  defp postcondition(_condition), do: error("invalid_action")

  defp revision(value) when is_integer(value) and value >= 0, do: :ok
  defp revision(_value), do: error("invalid_action")

  defp cursor(nil, _type), do: {:ok, nil}
  defp cursor(value, :uuid), do: uuid(value)
  defp cursor(value, :sequence), do: integer(value, 1, 9_223_372_036_854_775_807)

  defp integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(value, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= min and integer <= max -> {:ok, integer}
      _invalid -> error("invalid")
    end
  end

  defp integer(_value, _min, _max), do: error("invalid")

  defp body_integer(value, min, max)
       when is_integer(value) and value >= min and value <= max,
       do: {:ok, value}

  defp body_integer(_value, _min, _max), do: error("invalid")

  defp optional_uuid(nil), do: {:ok, nil}
  defp optional_uuid(value), do: uuid(value)

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> error("invalid")
    end
  end

  defp youtube_url(value) do
    with :ok <- bounded_string(value, 1, 2_048),
         :ok <- youtube_video_id(URI.parse(value)) do
      :ok
    else
      _invalid -> error("invalid_request")
    end
  rescue
    _exception -> error("invalid_request")
  end

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
    if String.contains?(video_id, "/"), do: error("invalid"), else: valid_video_id(video_id)
  end

  defp youtube_video_id(_uri), do: error("invalid")

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    _exception -> %{}
  end

  defp valid_video_id(video_id)
       when is_binary(video_id) and byte_size(video_id) in 6..64 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, video_id), do: :ok, else: error("invalid")
  end

  defp valid_video_id(_video_id), do: error("invalid")

  defp locale(value) do
    with :ok <- bounded_string(value, 1, 32),
         true <- Regex.match?(~r/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/, value) do
      :ok
    else
      _invalid -> error("invalid")
    end
  end

  defp navigation_url(value) do
    with :ok <- bounded_string(value, 1, 2_048),
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) and host != "" <-
           URI.parse(value) do
      :ok
    else
      _invalid -> error("invalid_action")
    end
  end

  defp origins(values) when is_list(values) and length(values) in 1..16 do
    if values == Enum.uniq(values) and Enum.all?(values, &valid_origin?/1),
      do: {:ok, values},
      else: error("invalid")
  end

  defp origins(_values), do: error("invalid")

  defp valid_origin?(value), do: Origin.canonical?(value)

  defp locator_value(value), do: bounded_string(value, 1, 512)
  defp optional_locator_value(nil), do: :ok
  defp optional_locator_value(value), do: locator_value(value)

  defp bounded_string(value, min, max)
       when is_binary(value) and byte_size(value) >= min and byte_size(value) <= max,
       do: :ok

  defp bounded_string(_value, _min, _max), do: error("invalid")

  defp exact_required_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys), do: :ok, else: error("invalid")
  end

  defp exact_keys(map, allowed) when is_map(map) do
    if Enum.all?(Map.keys(map), &(&1 in allowed)), do: :ok, else: error("invalid")
  end

  defp exact_keys(_map, _allowed), do: error("invalid")

  defp required_keys(map, required) do
    if Enum.all?(required, &Map.has_key?(map, &1)), do: :ok, else: error("invalid")
  end

  defp error(code), do: {:error, code}
end
