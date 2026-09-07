defmodule GSMLG.BrowserAgent.GeminiWorkflowTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.Sites.Gemini.UIContract
  alias GSMLG.BrowserAgent.Workflow.Decision
  alias GSMLG.BrowserAgent.Workflows.Gemini.{DeepResearch, YouTubeAnalysis}

  @fixture_dir Path.expand("../../fixtures/gemini", __DIR__)

  test "versioned UI contract recognizes sanitized semantic fixtures" do
    assert UIContract.id() == "gemini.ui/v1"

    for name <- ~w(chat login plan report) do
      fixture = load_fixture(name)
      assert {:ok, snapshot} = UIContract.recognize(fixture["observation"])
      assert Atom.to_string(snapshot.kind) == fixture["expected_kind"]
    end

    for fixture <- load_fixture("states")["fixtures"] do
      assert {:ok, snapshot} = UIContract.recognize(fixture["observation"])
      assert Atom.to_string(snapshot.kind) == fixture["expected_kind"]
    end

    assert {:ok, %{kind: :unknown}} =
             UIContract.recognize(%{
               "page_kind" => "document",
               "url" => "https://gemini.google.com/app",
               "alerts" => [],
               "semantic_tree" => []
             })
  end

  test "UI contract prioritizes ARIA role/name and exposes only policy-gated selector fallbacks" do
    observation = %{
      "url" => "https://gemini.google.com/app",
      "alerts" => [],
      "semantic_tree" => [
        %{
          "node_id" => "prompt",
          "role" => "textbox",
          "name" => "Enter a prompt",
          "attributes" => %{"data-testid" => "gemini-login"}
        }
      ]
    }

    assert {:ok, %{kind: :chat, prompt_ready?: true}} = UIContract.recognize(observation)

    assert [
             %{"role" => "textbox", "accessible_name" => "Enter a prompt"},
             %{"attribute" => %{"name" => "type", "value" => "text"}}
             | _rest
           ] = UIContract.selector_candidates(:prompt)

    refute Enum.any?(UIContract.selector_candidates(:prompt), &Map.has_key?(&1, "css"))

    assert %{"css" => _selector} =
             List.last(UIContract.selector_candidates(:prompt, allow_css: true))
  end

  test "report fixture extracts bounded source URLs from the semantic contract" do
    assert {:ok, snapshot} =
             load_fixture("report")["observation"] |> UIContract.recognize()

    assert snapshot.sources == [
             %{"title" => "Example source", "url" => "https://example.com/source"}
           ]
  end

  test "deep research initial state strictly validates its versioned input" do
    assert {:ok, state} = DeepResearch.initial_state(deep_input())
    assert state.phase == :acquire_profile
    assert state.stable_hash_count == 0
    assert state.prompt_submitted == false

    assert {:error, :invalid_workflow_input} =
             DeepResearch.initial_state(Map.put(deep_input(), "raw_cdp", true))

    assert {:error, :invalid_workflow_input} =
             DeepResearch.initial_state(Map.put(deep_input(), "output_locale", "not_a_locale"))
  end

  test "deep research has deterministic transitions for every fixed phase" do
    {:ok, state} = DeepResearch.initial_state(deep_input())

    state = assert_phase(state, %{kind: :chat}, :launch_profile, :emit_event)
    state = assert_phase(state, %{kind: :chat}, :attach_browser, :emit_event)
    state = assert_phase(state, %{kind: :chat}, :inspect_auth, :emit_event)
    state = assert_phase(state, %{kind: :chat}, :open_chat, :emit_event)
    state = assert_phase(state, %{kind: :chat}, :select_deep_research, :action)
    state = assert_phase(state, %{kind: :chat}, :submit_prompt, :action)

    assert {:ok, filled, %Decision{type: :action, action: %{"type" => "fill"}}} =
             DeepResearch.transition(state, %{kind: :chat})

    assert filled.phase == :submit_prompt
    assert filled.submit_stage == :send

    assert {:ok, state, %Decision{type: :action, action: %{"type" => "press_key"}}} =
             DeepResearch.transition(filled, %{kind: :chat})

    assert state.phase == :wait_plan
    assert state.prompt_submitted

    assert {:ok, state, %Decision{type: :action}} =
             DeepResearch.transition(state, %{kind: :plan, approve_available?: true})

    assert state.phase == :approve_plan
    state = assert_phase(state, %{kind: :researching}, :researching, :wait)

    report = deep_report()
    state = assert_phase(state, report, :stabilize_report, :wait)
    assert state.stable_hash_count == 1

    assert {:ok, state, %Decision{type: :wait}} = DeepResearch.transition(state, report)
    assert state.stable_hash_count == 2

    assert {:ok, state, %Decision{type: :emit_event}} = DeepResearch.transition(state, report)
    assert state.phase == :extract_report
    assert state.stable_hash_count == 3

    assert {:ok, state, %Decision{type: :emit_event}} = DeepResearch.transition(state, report)
    assert state.phase == :produce_artifacts

    assert {:ok, state, %Decision{type: :complete, result: result}} =
             DeepResearch.transition(state, report)

    assert state.phase == :complete
    assert Map.keys(result) |> Enum.sort() == ~w(html markdown sources structured)a |> Enum.sort()
  end

  test "report stability resets on a changed canonical hash and requires three complete matches" do
    state = %{deep_state(:stabilize_report) | stable_hash: "old", stable_hash_count: 2}
    changed = deep_report("# Summary\nChanged\n# Evidence\nChanged")

    assert {:ok, changed_state, %Decision{type: :wait}} =
             DeepResearch.transition(state, changed)

    assert changed_state.stable_hash_count == 1

    generating = %{changed | generating?: true}

    assert {:ok, reset, %Decision{type: :wait}} =
             DeepResearch.transition(changed_state, generating)

    assert reset.stable_hash_count == 0
  end

  test "auto approve false requests human and never produces an approve action" do
    state = %{deep_state(:wait_plan) | input: Map.put(deep_input(), "auto_approve_plan", false)}

    assert {:ok, next, %Decision{type: :request_human, reason: :plan_approval_required}} =
             DeepResearch.transition(state, %{kind: :plan, approve_available?: true})

    assert next.status == :waiting_human
    refute inspect(next) =~ "gemini-plan-approve"
  end

  test "deep research recognizes every intervention and stable failure" do
    state = deep_state(:inspect_auth)

    for reason <-
          ~w(login_required reauth_required passkey_required two_factor_required captcha_required account_warning)a do
      assert {:ok, waiting, %Decision{type: :request_human, reason: ^reason}} =
               DeepResearch.transition(state, %{kind: reason})

      assert waiting.status == :waiting_human
    end

    assert {:ok, _waiting, %Decision{reason: :ui_contract_mismatch}} =
             DeepResearch.transition(state, %{kind: :unknown})

    assert {:ok, failed, %Decision{type: :fail, code: :quota_exceeded}} =
             DeepResearch.transition(state, %{kind: :quota})

    assert failed.status == :failed
  end

  test "deep research refuses a stable report missing required sections" do
    report = %{deep_report() | sections: ["Summary"]}

    state = %{
      deep_state(:stabilize_report)
      | stable_hash_count: 2,
        stable_hash: report.canonical_hash
    }

    assert {:ok, failed, %Decision{type: :fail, code: :required_sections_missing}} =
             DeepResearch.transition(state, report)

    assert failed.status == :failed
  end

  test "deep research result accepts only structured HTTPS source entries" do
    state = deep_state(:extract_report)

    invalid =
      put_in(deep_report(), [:sources], [
        %{"title" => "Leaked", "url" => "file:///etc/passwd"}
      ])

    assert {:error, :report_extraction_failed} = DeepResearch.extract_result(state, invalid)
  end

  test "YouTube validates finite profiles and produces every required result field" do
    assert {:error, :invalid_workflow_input} =
             YouTubeAnalysis.initial_state(
               Map.put(youtube_input(), "analysis_profile", "arbitrary")
             )

    for profile <- ~w(summary technical_review timeline fact_check action_items) do
      assert {:ok, %{input: %{"analysis_profile" => ^profile}}} =
               YouTubeAnalysis.initial_state(
                 Map.put(youtube_input(), "analysis_profile", profile)
               )
    end

    state = youtube_state(:stabilize_report)
    report = youtube_report()
    {:ok, one, %Decision{type: :wait}} = YouTubeAnalysis.transition(state, report)
    {:ok, two, %Decision{type: :wait}} = YouTubeAnalysis.transition(one, report)
    {:ok, extracted, %Decision{type: :emit_event}} = YouTubeAnalysis.transition(two, report)
    {:ok, producing, %Decision{type: :emit_event}} = YouTubeAnalysis.transition(extracted, report)

    assert {:ok, complete, %Decision{type: :complete, result: result}} =
             YouTubeAnalysis.transition(producing, report)

    assert complete.phase == :complete

    assert Enum.sort(Map.keys(result)) ==
             Enum.sort(
               ~w(summary timeline key_arguments evidence action_items uncertain_claims source_video)
             )
  end

  test "YouTube requires a real video identity and the extracted source must match it" do
    for invalid <- [
          "https://www.youtube.com/watch",
          "https://www.youtube.com/watch?v=",
          "https://youtu.be/",
          "http://www.youtube.com/watch?v=dQw4w9WgXcQ",
          "https://youtube.example/watch?v=dQw4w9WgXcQ"
        ] do
      assert {:error, :invalid_workflow_input} =
               YouTubeAnalysis.initial_state(Map.put(youtube_input(), "youtube_url", invalid))
    end

    mismatch =
      put_in(youtube_report(), [:analysis, "source_video"], "https://youtu.be/aaaaaaaaaaa")

    assert {:error, :youtube_source_video_mismatch} =
             YouTubeAnalysis.extract_result(youtube_state(:extract_report), mismatch)
  end

  test "YouTube enforces content-grounded evidence and profile-specific nonempty sections" do
    for {profile, field} <- [
          {"summary", "summary"},
          {"technical_review", "key_arguments"},
          {"timeline", "timeline"},
          {"fact_check", "evidence"},
          {"action_items", "action_items"}
        ] do
      input = Map.put(youtube_input(), "analysis_profile", profile)
      {:ok, state} = YouTubeAnalysis.initial_state(input)
      report = youtube_report()
      analysis = Map.put(report.analysis, field, if(field == "summary", do: "", else: []))

      assert {:error, :youtube_result_incomplete} =
               YouTubeAnalysis.extract_result(state, %{report | analysis: analysis})
    end

    ungrounded = put_in(youtube_report(), [:analysis, "evidence"], ["vague assertion"])

    assert {:error, :youtube_result_ungrounded} =
             YouTubeAnalysis.extract_result(youtube_state(:extract_report), ungrounded)
  end

  test "YouTube never completes unavailable, restricted, inaccessible, title-only, or incomplete analysis" do
    state = youtube_state(:researching)

    for {kind, code} <- [
          video_unavailable: :video_unavailable,
          age_restricted: :video_age_restricted,
          region_restricted: :video_region_restricted,
          video_inaccessible: :gemini_video_inaccessible,
          title_only: :youtube_title_only
        ] do
      assert {:ok, %{status: :failed}, %Decision{type: :fail, code: ^code}} =
               YouTubeAnalysis.transition(state, %{kind: kind})
    end

    incomplete = put_in(youtube_report(), [:analysis, "timeline"], [])

    stable = youtube_state(:stabilize_report)

    stable = %{
      stable
      | input: Map.put(stable.input, "analysis_profile", "timeline"),
        stable_hash_count: 2,
        stable_hash: incomplete.canonical_hash
    }

    assert {:ok, %{status: :failed}, %Decision{code: :youtube_result_incomplete}} =
             YouTubeAnalysis.transition(stable, incomplete)
  end

  defp assert_phase(state, observation, phase, decision_type) do
    assert {:ok, next, %Decision{type: ^decision_type}} =
             DeepResearch.transition(state, observation)

    assert next.phase == phase
    next
  end

  defp deep_state(phase) do
    {:ok, state} = DeepResearch.initial_state(deep_input())
    %{state | phase: phase, status: :running}
  end

  defp youtube_state(phase) do
    {:ok, state} = YouTubeAnalysis.initial_state(youtube_input())
    %{state | phase: phase, status: :running}
  end

  defp deep_input do
    %{
      "prompt" => "Compare a sanitized example",
      "output_locale" => "en",
      "research_scope" => "web",
      "required_sections" => ["Summary", "Evidence"],
      "auto_approve_plan" => true
    }
  end

  defp deep_report(markdown \\ "# Summary\nExample\n# Evidence\nPublic source") do
    %{
      kind: :report,
      complete?: true,
      generating?: false,
      markdown: markdown,
      html: "<h1>Summary</h1><p>Example</p><h1>Evidence</h1><p>Public source</p>",
      structured: %{"sections" => ["Summary", "Evidence"]},
      sections: ["Summary", "Evidence"],
      sources: [%{"title" => "Public source", "url" => "https://example.com/source"}],
      canonical_hash: UIContract.canonical_hash(markdown)
    }
  end

  defp youtube_input do
    %{
      "youtube_url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
      "analysis_profile" => "summary",
      "output_locale" => "en",
      "custom_instructions" => "Use timestamps",
      "use_deep_research" => false
    }
  end

  defp youtube_report do
    analysis = %{
      "summary" => "Summary",
      "timeline" => [%{"timestamp" => "00:10", "summary" => "Opening"}],
      "key_arguments" => ["Argument"],
      "evidence" => [
        %{"claim" => "Evidence", "support" => "Visible in the video", "timestamp" => "00:10"}
      ],
      "action_items" => ["Action"],
      "uncertain_claims" => [],
      "source_video" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
    }

    markdown = "# Summary\nSummary\n# Timeline\n00:10 Opening"

    %{
      kind: :report,
      complete?: true,
      generating?: false,
      markdown: markdown,
      analysis: analysis,
      canonical_hash: UIContract.canonical_hash(markdown)
    }
  end

  defp load_fixture(name) do
    @fixture_dir
    |> Path.join("#{name}.json")
    |> File.read!()
    |> JSON.decode!()
  end
end
