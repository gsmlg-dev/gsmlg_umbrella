defmodule GSMLG.BrowserAgent.Workflows.Gemini.YouTubeAnalysis do
  @moduledoc "Pure `gemini.youtube_analysis/v1` workflow state machine."

  @behaviour GSMLG.BrowserAgent.Workflow

  alias GSMLG.BrowserAgent.Sites.Gemini.UIContract
  alias GSMLG.BrowserAgent.Workflow.Decision

  @phases [
    :acquire_profile,
    :launch_profile,
    :attach_browser,
    :inspect_auth,
    :open_chat,
    :submit_video,
    :researching,
    :stabilize_report,
    :extract_report,
    :produce_artifacts,
    :complete
  ]

  @impl true
  def id, do: "gemini.youtube_analysis/v1"
  @impl true
  def version, do: 1
  @impl true
  def phases, do: @phases

  @profiles ~w(summary technical_review timeline fact_check action_items)
  @input_keys ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research)
  @required ~w(youtube_url analysis_profile output_locale custom_instructions use_deep_research)
  @result_keys ~w(summary timeline key_arguments evidence action_items uncertain_claims source_video)

  @impl true
  def input_schema, do: %{required: @required, optional: @input_keys -- @required}
  @impl true
  def output_schema,
    do: %{
      required: ~w(report.markdown report.json sources.json),
      optional: ~w(report.html screenshot.png)
    }

  @impl true
  def required_origins,
    do: [
      "https://gemini.google.com",
      "https://accounts.google.com",
      "https://www.youtube.com",
      "https://youtube.com",
      "https://youtu.be"
    ]

  @impl true
  def profile_capabilities, do: ["gemini_authenticated"]

  @impl true
  def initial_state(input) when is_map(input) do
    keys = Map.keys(input)

    if keys -- @input_keys == [] and @required -- keys == [] and
         match?({:ok, _video_id}, youtube_video_id(input["youtube_url"])) and
         input["analysis_profile"] in @profiles and
         valid_locale?(input["output_locale"]) and
         is_binary(input["custom_instructions"]) and
         byte_size(input["custom_instructions"]) <= 8_192 and
         is_boolean(input["use_deep_research"]) do
      {:ok,
       %{
         workflow: id(),
         phase: :acquire_profile,
         status: :running,
         input: input,
         submit_stage: :fill,
         prompt_submitted: false,
         stable_hash: nil,
         stable_hash_count: 0,
         result: nil,
         resume_phase: nil
       }}
    else
      {:error, :invalid_workflow_input}
    end
  end

  def initial_state(_input), do: {:error, :invalid_workflow_input}

  @impl true
  def transition(%{status: :running} = state, snapshot) when is_map(snapshot) do
    case exceptional(snapshot) do
      nil -> transition_phase(state, snapshot)
      {:human, reason} -> human(state, reason)
      {:fail, code} -> fail(state, code)
    end
  end

  def transition(%{status: status}, _snapshot) when status in [:completed, :failed, :cancelled],
    do: {:error, :workflow_terminal}

  def transition(_state, _snapshot), do: {:error, :invalid_workflow_state}

  defp transition_phase(%{phase: :acquire_profile} = state, _snapshot),
    do: phase(state, :launch_profile)

  defp transition_phase(%{phase: :launch_profile} = state, _snapshot),
    do: phase(state, :attach_browser)

  defp transition_phase(%{phase: :attach_browser} = state, _snapshot),
    do: phase(state, :inspect_auth)

  defp transition_phase(%{phase: :inspect_auth} = state, %{kind: :chat}),
    do: phase(state, :open_chat)

  defp transition_phase(%{phase: :open_chat} = state, %{kind: :chat}) do
    {:ok, %{state | phase: :submit_video, submit_stage: :fill},
     Decision.action(%{"type" => "navigate", "url" => "https://gemini.google.com/app"})}
  end

  defp transition_phase(%{phase: :submit_video, submit_stage: :fill} = state, %{kind: :chat}) do
    {:ok, %{state | submit_stage: :send},
     Decision.action(%{
       "type" => "fill",
       "locator" => UIContract.selectors().prompt,
       "text" => youtube_prompt(state.input),
       "postconditions" => [
         %{"type" => "node_present", "locator" => UIContract.selectors().prompt}
       ]
     })}
  end

  defp transition_phase(%{phase: :submit_video, submit_stage: :send} = state, %{kind: :chat}) do
    {:ok, %{state | phase: :researching, prompt_submitted: true},
     Decision.action(%{"type" => "press_key", "key" => "Enter", "postconditions" => []})}
  end

  defp transition_phase(%{phase: :researching} = state, %{kind: :researching}),
    do: {:ok, state, Decision.wait(5_000)}

  defp transition_phase(%{phase: :researching} = state, %{kind: :report} = report),
    do: stabilize(%{state | phase: :stabilize_report}, report)

  defp transition_phase(%{phase: :stabilize_report} = state, %{kind: :report} = report),
    do: stabilize(state, report)

  defp transition_phase(%{phase: :extract_report} = state, report) do
    case extract_result(state, report) do
      {:ok, result} ->
        {:ok, %{state | phase: :produce_artifacts, result: result},
         Decision.emit("workflow.phase_changed", %{"phase" => "produce_artifacts"})}

      {:error, code} ->
        fail(state, code)
    end
  end

  defp transition_phase(%{phase: :produce_artifacts, result: result} = state, _snapshot)
       when is_map(result),
       do: {:ok, %{state | phase: :complete, status: :completed}, Decision.complete(result)}

  defp transition_phase(state, %{kind: :unknown}), do: human(state, :ui_contract_mismatch)
  defp transition_phase(state, _snapshot), do: {:ok, state, Decision.wait(1_000)}

  defp stabilize(state, report) do
    if report[:complete?] == true and report[:generating?] == false and
         valid_string?(report[:markdown], 1_048_576) do
      hash = UIContract.canonical_hash(report.markdown)
      count = if state.stable_hash == hash, do: state.stable_hash_count + 1, else: 1
      next = %{state | stable_hash: hash, stable_hash_count: count}

      if count >= 3 do
        case extract_result(next, report) do
          {:ok, _result} ->
            {:ok, %{next | phase: :extract_report},
             Decision.emit("workflow.phase_changed", %{"phase" => "extract_report"})}

          {:error, code} ->
            fail(next, code)
        end
      else
        {:ok, next, Decision.wait(2_000)}
      end
    else
      {:ok, %{state | stable_hash: nil, stable_hash_count: 0}, Decision.wait(2_000)}
    end
  end

  @impl true
  def extract_result(state, %{kind: :report, analysis: analysis}) when is_map(analysis) do
    with :ok <- validate_result_shape(analysis),
         {:ok, expected_video_id} <- youtube_video_id(state.input["youtube_url"]),
         {:ok, actual_video_id} <- youtube_video_id(analysis["source_video"]),
         true <- expected_video_id == actual_video_id,
         :ok <- validate_profile_result(state.input["analysis_profile"], analysis),
         :ok <- validate_grounded_evidence(analysis["evidence"]) do
      {:ok,
       Map.put(
         analysis,
         "source_video",
         "https://www.youtube.com/watch?v=#{expected_video_id}"
       )}
    else
      false -> {:error, :youtube_source_video_mismatch}
      {:error, :invalid_youtube_source} -> {:error, :youtube_source_video_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :youtube_result_incomplete}
    end
  end

  def extract_result(_state, _report), do: {:error, :youtube_result_incomplete}

  defp validate_result_shape(analysis) do
    valid? =
      Map.keys(analysis) |> Enum.sort() == Enum.sort(@result_keys) and
        is_binary(analysis["summary"]) and byte_size(analysis["summary"]) <= 1_048_576 and
        is_list(analysis["timeline"]) and valid_timeline?(analysis["timeline"]) and
        string_list?(analysis["key_arguments"]) and is_list(analysis["evidence"]) and
        string_list?(analysis["action_items"]) and string_list?(analysis["uncertain_claims"])

    if valid?, do: :ok, else: {:error, :youtube_result_incomplete}
  end

  defp valid_timeline?(timeline) do
    Enum.all?(timeline, fn
      %{"timestamp" => timestamp, "summary" => summary} = item when map_size(item) == 2 ->
        is_binary(timestamp) and Regex.match?(~r/\A(?:\d{1,2}:)?\d{2}:\d{2}\z/, timestamp) and
          valid_string?(summary, 4_096)

      _invalid ->
        false
    end)
  end

  defp validate_grounded_evidence(evidence) when is_list(evidence) and evidence != [] do
    valid? =
      Enum.all?(evidence, fn
        %{"claim" => claim, "support" => support, "timestamp" => timestamp} = item
        when map_size(item) == 3 ->
          valid_string?(claim, 4_096) and valid_string?(support, 8_192) and
            timestamp?(timestamp)

        _invalid ->
          false
      end)

    if valid?, do: :ok, else: {:error, :youtube_result_ungrounded}
  end

  defp validate_grounded_evidence(_evidence), do: {:error, :youtube_result_ungrounded}

  defp validate_profile_result("summary", analysis) do
    if valid_string?(analysis["summary"], 1_048_576),
      do: :ok,
      else: {:error, :youtube_result_incomplete}
  end

  defp validate_profile_result("technical_review", analysis) do
    if nonempty_list?(analysis["key_arguments"]),
      do: :ok,
      else: {:error, :youtube_result_incomplete}
  end

  defp validate_profile_result("timeline", analysis) do
    if nonempty_list?(analysis["timeline"]),
      do: :ok,
      else: {:error, :youtube_result_incomplete}
  end

  defp validate_profile_result("fact_check", analysis) do
    if nonempty_list?(analysis["evidence"]),
      do: :ok,
      else: {:error, :youtube_result_incomplete}
  end

  defp validate_profile_result("action_items", analysis) do
    if nonempty_list?(analysis["action_items"]),
      do: :ok,
      else: {:error, :youtube_result_incomplete}
  end

  defp exceptional(%{kind: kind})
       when kind in ~w(login_required reauth_required passkey_required two_factor_required captcha_required account_warning)a,
       do: {:human, kind}

  defp exceptional(%{kind: :video_unavailable}), do: {:fail, :video_unavailable}
  defp exceptional(%{kind: :age_restricted}), do: {:fail, :video_age_restricted}
  defp exceptional(%{kind: :region_restricted}), do: {:fail, :video_region_restricted}
  defp exceptional(%{kind: :video_inaccessible}), do: {:fail, :gemini_video_inaccessible}
  defp exceptional(%{kind: :title_only}), do: {:fail, :youtube_title_only}
  defp exceptional(%{kind: :quota}), do: {:fail, :quota_exceeded}
  defp exceptional(%{kind: :error}), do: {:fail, :gemini_error}
  defp exceptional(_snapshot), do: nil

  defp phase(state, phase),
    do:
      {:ok, %{state | phase: phase},
       Decision.emit("workflow.phase_changed", %{"phase" => Atom.to_string(phase)})}

  defp human(state, reason),
    do:
      {:ok, %{state | status: :waiting_human, resume_phase: state.phase},
       Decision.request_human(reason)}

  defp fail(state, code), do: {:ok, %{state | status: :failed}, Decision.fail(code)}

  defp youtube_prompt(input) do
    [
      "Analyze this YouTube video: ",
      input["youtube_url"],
      "\nProfile: ",
      input["analysis_profile"],
      "\nOutput locale: ",
      input["output_locale"],
      "\nInstructions: ",
      input["custom_instructions"]
    ]
    |> IO.iodata_to_binary()
  end

  defp youtube_video_id(url) when is_binary(url) and byte_size(url) <= 2_048 do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port, path: "/watch", userinfo: nil, fragment: nil} =
          uri
      when host in ["www.youtube.com", "youtube.com"] and port in [nil, 443] ->
        uri.query
        |> decode_query()
        |> Map.get("v")
        |> valid_video_id()

      %URI{
        scheme: "https",
        host: "youtu.be",
        port: port,
        path: "/" <> video_id,
        userinfo: nil,
        fragment: nil
      }
      when port in [nil, 443] ->
        if String.contains?(video_id, "/"),
          do: {:error, :invalid_youtube_source},
          else: valid_video_id(video_id)

      _invalid ->
        {:error, :invalid_youtube_source}
    end
  end

  defp youtube_video_id(_url), do: {:error, :invalid_youtube_source}

  defp decode_query(nil), do: %{}

  defp decode_query(query) do
    URI.decode_query(query)
  rescue
    _exception -> %{}
  end

  defp valid_video_id(video_id)
       when is_binary(video_id) and byte_size(video_id) in 6..64 do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, video_id),
      do: {:ok, video_id},
      else: {:error, :invalid_youtube_source}
  end

  defp valid_video_id(_video_id), do: {:error, :invalid_youtube_source}

  defp nonempty_list?(items), do: is_list(items) and items != []
  defp string_list?(items), do: is_list(items) and Enum.all?(items, &valid_string?(&1, 8_192))

  defp timestamp?(timestamp),
    do: is_binary(timestamp) and Regex.match?(~r/\A(?:\d{1,2}:)?\d{2}:\d{2}\z/, timestamp)

  defp valid_locale?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/, value)

  defp valid_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)
end
