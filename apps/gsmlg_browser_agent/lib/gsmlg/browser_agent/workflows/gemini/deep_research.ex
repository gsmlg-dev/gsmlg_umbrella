defmodule GSMLG.BrowserAgent.Workflows.Gemini.DeepResearch do
  @moduledoc "Pure `gemini.deep_research/v1` workflow state machine."

  @behaviour GSMLG.BrowserAgent.Workflow

  alias GSMLG.BrowserAgent.Sites.Gemini.UIContract
  alias GSMLG.BrowserAgent.Workflow.Decision

  @phases [
    :acquire_profile,
    :launch_profile,
    :attach_browser,
    :inspect_auth,
    :open_chat,
    :select_deep_research,
    :submit_prompt,
    :wait_plan,
    :approve_plan,
    :researching,
    :stabilize_report,
    :extract_report,
    :produce_artifacts,
    :complete
  ]

  @input_keys ~w(prompt output_locale research_scope required_sections auto_approve_plan)
  @required_input_keys ~w(prompt output_locale research_scope required_sections auto_approve_plan)

  @impl true
  def id, do: "gemini.deep_research/v1"
  @impl true
  def version, do: 1
  @impl true
  def phases, do: @phases
  @impl true
  def input_schema,
    do: %{required: @required_input_keys, optional: @input_keys -- @required_input_keys}

  @impl true
  def output_schema,
    do: %{
      required: ~w(report.markdown report.json sources.json),
      optional: ~w(report.html screenshot.png)
    }

  @impl true
  def required_origins, do: ["https://gemini.google.com", "https://accounts.google.com"]
  @impl true
  def profile_capabilities, do: ["gemini_authenticated"]

  @impl true
  def initial_state(input) when is_map(input) do
    with :ok <- exact_input(input),
         true <- valid_string?(input["prompt"], 65_536),
         true <- valid_locale?(input["output_locale"]),
         true <- valid_string?(input["research_scope"], 1_024),
         true <- valid_sections?(input["required_sections"]),
         true <- is_boolean(input["auto_approve_plan"]) do
      {:ok,
       %{
         workflow: id(),
         phase: :acquire_profile,
         status: :running,
         input: input,
         submit_stage: :fill,
         prompt_submitted: false,
         plan_approved: false,
         stable_hash: nil,
         stable_hash_count: 0,
         result: nil,
         resume_phase: nil
       }}
    else
      _invalid -> {:error, :invalid_workflow_input}
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
    next = %{state | phase: :select_deep_research}

    {:ok, next,
     Decision.action(%{"type" => "navigate", "url" => "https://gemini.google.com/app"})}
  end

  defp transition_phase(%{phase: :select_deep_research} = state, %{kind: :chat}) do
    next = %{state | phase: :submit_prompt, submit_stage: :fill}

    {:ok, next,
     Decision.action(%{
       "type" => "click",
       "locator" => UIContract.selectors().deep_research,
       "postconditions" => [
         %{"type" => "node_present", "locator" => UIContract.selectors().prompt}
       ]
     })}
  end

  defp transition_phase(
         %{phase: :submit_prompt, submit_stage: :fill} = state,
         %{kind: :chat}
       ) do
    next = %{state | submit_stage: :send}

    {:ok, next,
     Decision.action(%{
       "type" => "fill",
       "locator" => UIContract.selectors().prompt,
       "text" => state.input["prompt"],
       "postconditions" => [
         %{"type" => "node_present", "locator" => UIContract.selectors().prompt}
       ]
     })}
  end

  defp transition_phase(
         %{phase: :submit_prompt, submit_stage: :send} = state,
         %{kind: :chat}
       ) do
    next = %{state | phase: :wait_plan, prompt_submitted: true}

    {:ok, next,
     Decision.action(%{
       "type" => "press_key",
       "key" => "Enter",
       "postconditions" => []
     })}
  end

  defp transition_phase(%{phase: :wait_plan} = state, %{kind: :plan} = snapshot) do
    if state.input["auto_approve_plan"] do
      if snapshot[:approve_available?] do
        next = %{state | phase: :approve_plan}

        {:ok, next,
         Decision.action(%{
           "type" => "click",
           "locator" => UIContract.selectors().plan_approve,
           "postconditions" => [
             %{"type" => "node_absent", "locator" => UIContract.selectors().plan_approve}
           ]
         })}
      else
        human(state, :ui_contract_mismatch)
      end
    else
      human(state, :plan_approval_required)
    end
  end

  defp transition_phase(%{phase: :wait_plan} = state, %{kind: :researching}),
    do: phase_wait(state, :researching)

  defp transition_phase(%{phase: :approve_plan} = state, %{kind: :researching}),
    do: {:ok, %{state | phase: :researching, plan_approved: true}, Decision.wait(1_000)}

  defp transition_phase(%{phase: :approve_plan} = state, %{kind: :plan}),
    do: {:ok, state, Decision.wait(1_000)}

  defp transition_phase(%{phase: :researching} = state, %{kind: :researching}),
    do: {:ok, state, Decision.wait(5_000)}

  defp transition_phase(%{phase: :researching} = state, %{kind: :report} = report),
    do: stabilize(%{state | phase: :stabilize_report}, report)

  defp transition_phase(%{phase: :stabilize_report} = state, %{kind: :report} = report),
    do: stabilize(state, report)

  defp transition_phase(%{phase: :extract_report} = state, report) do
    with {:ok, result} <- extract_result(state, report) do
      next = %{state | phase: :produce_artifacts, result: result}
      {:ok, next, Decision.emit("workflow.phase_changed", %{"phase" => "produce_artifacts"})}
    else
      {:error, code} -> fail(state, code)
    end
  end

  defp transition_phase(%{phase: :produce_artifacts, result: result} = state, _snapshot)
       when is_map(result) do
    {:ok, %{state | phase: :complete, status: :completed}, Decision.complete(result)}
  end

  defp transition_phase(state, %{kind: :unknown}), do: human(state, :ui_contract_mismatch)
  defp transition_phase(state, _snapshot), do: {:ok, state, Decision.wait(1_000)}

  defp stabilize(state, report) do
    if report[:complete?] == true and report[:generating?] == false and
         valid_string?(report[:markdown], 1_048_576) do
      hash = UIContract.canonical_hash(report.markdown)
      count = if state.stable_hash == hash, do: state.stable_hash_count + 1, else: 1
      next = %{state | stable_hash: hash, stable_hash_count: count}

      if count >= 3 do
        if required_sections?(state.input["required_sections"], report[:sections]) do
          {:ok, %{next | phase: :extract_report},
           Decision.emit("workflow.phase_changed", %{"phase" => "extract_report"})}
        else
          fail(next, :required_sections_missing)
        end
      else
        {:ok, next, Decision.wait(2_000)}
      end
    else
      {:ok, %{state | stable_hash: nil, stable_hash_count: 0}, Decision.wait(2_000)}
    end
  end

  @impl true
  def extract_result(_state, %{kind: :report} = report) do
    result = %{
      markdown: report[:markdown],
      html: report[:html],
      structured: report[:structured],
      sources: report[:sources]
    }

    if is_binary(result.markdown) and is_binary(result.html) and is_map(result.structured) and
         valid_sources?(result.sources),
       do: {:ok, result},
       else: {:error, :report_extraction_failed}
  end

  def extract_result(_state, _report), do: {:error, :report_extraction_failed}

  defp phase(state, phase),
    do:
      {:ok, %{state | phase: phase},
       Decision.emit("workflow.phase_changed", %{"phase" => Atom.to_string(phase)})}

  defp phase_wait(state, phase), do: {:ok, %{state | phase: phase}, Decision.wait(1_000)}

  defp human(state, reason) do
    {:ok, %{state | status: :waiting_human, resume_phase: state.phase},
     Decision.request_human(reason)}
  end

  defp fail(state, code),
    do: {:ok, %{state | status: :failed}, Decision.fail(code)}

  defp exceptional(%{kind: kind})
       when kind in ~w(login_required reauth_required passkey_required two_factor_required captcha_required account_warning)a,
       do: {:human, kind}

  defp exceptional(%{kind: :quota}), do: {:fail, :quota_exceeded}
  defp exceptional(%{kind: :error}), do: {:fail, :gemini_error}
  defp exceptional(_snapshot), do: nil

  defp exact_input(input) do
    keys = Map.keys(input)
    if keys -- @input_keys == [] and @required_input_keys -- keys == [], do: :ok, else: :error
  end

  defp valid_sections?(sections) when is_list(sections) and length(sections) in 1..32 do
    Enum.all?(sections, &valid_string?(&1, 128)) and
      length(Enum.uniq(sections)) == length(sections)
  end

  defp valid_sections?(_sections), do: false

  defp required_sections?(required, actual) when is_list(actual) do
    actual = MapSet.new(Enum.map(actual, &normalize_section/1))
    Enum.all?(required, &MapSet.member?(actual, normalize_section(&1)))
  end

  defp required_sections?(_required, _actual), do: false

  defp valid_sources?(sources) when is_list(sources) do
    Enum.all?(sources, fn
      %{"title" => title, "url" => url} = source when map_size(source) == 2 ->
        valid_string?(title, 1_024) and valid_source_url?(url)

      _invalid ->
        false
    end)
  end

  defp valid_sources?(_sources), do: false

  defp valid_source_url?(url) when is_binary(url) and byte_size(url) in 1..2_048 do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil} -> is_binary(host) and host != ""
      _unsafe -> false
    end
  end

  defp valid_source_url?(_url), do: false

  defp normalize_section(section), do: section |> String.trim() |> String.downcase()

  defp valid_locale?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-zA-Z]{2,3}(?:-[a-zA-Z0-9]{2,8})*\z/, value)

  defp valid_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)
end
