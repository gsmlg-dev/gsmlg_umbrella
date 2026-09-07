defmodule GSMLG.BrowserAgent.WorkflowContractTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Intervention, Policy, Telemetry, Workflow}
  alias GSMLG.BrowserAgent.Workflows.Gemini.{DeepResearch, YouTubeAnalysis}

  @event_vocabulary ~w(workflow.accepted workflow.started workflow.phase_changed intervention.required intervention.cleared artifact.available result.available workflow.failed workflow.cancelled workflow.completed)

  test "freezes the finite workflow decision and event vocabularies" do
    assert Workflow.decision_types() == [
             :action,
             :wait,
             :emit_event,
             :request_human,
             :complete,
             :fail
           ]

    assert Workflow.event_vocabulary() == @event_vocabulary
  end

  test "publishes both versioned Gemini contracts and their fixed phases" do
    assert DeepResearch.id() == "gemini.deep_research/v1"

    assert DeepResearch.phases() == [
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

    assert YouTubeAnalysis.id() == "gemini.youtube_analysis/v1"
    assert :stabilize_report in YouTubeAnalysis.phases()
    assert :complete in YouTubeAnalysis.phases()
  end

  test "workflow inputs cannot shadow trusted top-level profile or actor identity" do
    deep_input = %{
      "prompt" => "Research BEAM",
      "output_locale" => "en-US",
      "research_scope" => "primary sources",
      "required_sections" => ["Summary"],
      "auto_approve_plan" => true
    }

    youtube_input = %{
      "youtube_url" => "https://www.youtube.com/watch?v=abcdef",
      "analysis_profile" => "summary",
      "output_locale" => "en-US",
      "custom_instructions" => "",
      "use_deep_research" => false
    }

    assert DeepResearch.input_schema().optional == []
    assert YouTubeAnalysis.input_schema().optional == []

    for module <- [DeepResearch, YouTubeAnalysis], input <- [deep_input, youtube_input] do
      if match?({:ok, _state}, module.initial_state(input)) do
        assert {:error, :invalid_workflow_input} =
                 module.initial_state(Map.put(input, "profile_id", "untrusted-profile"))

        assert {:error, :invalid_workflow_input} =
                 module.initial_state(Map.put(input, "requested_by_actor_id", "untrusted-actor"))
      end
    end
  end

  test "all intervention reason codes include plan approval" do
    assert Intervention.reason_codes() == [
             :login_required,
             :reauth_required,
             :passkey_required,
             :two_factor_required,
             :captcha_required,
             :account_warning,
             :ui_contract_mismatch,
             :action_outcome_unknown,
             :plan_approval_required
           ]
  end

  test "constrained policy rejects scripts, raw CDP, stale revisions, and unknown origins" do
    context = %{
      revision: 7,
      allowed_origins: ["https://gemini.google.com"],
      max_observation_bytes: 1_024
    }

    assert {:error, :policy_action_not_allowed} =
             Policy.validate_decision(%{"type" => "javascript", "script" => "secret"}, context)

    assert {:error, :policy_action_not_allowed} =
             Policy.validate_decision(
               %{"type" => "raw_cdp", "method" => "Runtime.evaluate"},
               context
             )

    assert {:error, :stale_observation} =
             Policy.validate_decision(
               %{"type" => "click", "expected_revision" => 6, "locator" => %{"text" => "Go"}},
               context
             )

    assert {:error, :navigation_not_allowed} =
             Policy.validate_decision(
               %{
                 "type" => "navigate",
                 "expected_revision" => 7,
                 "url" => "https://example.invalid"
               },
               context
             )

    assert {:error, :policy_action_not_allowed} =
             Policy.validate_decision(
               %{
                 "type" => "fill",
                 "expected_revision" => 7,
                 "locator" => %{"role" => "textbox"},
                 "text" => String.duplicate("x", 65_537)
               },
               context
             )

    assert {:error, :policy_action_not_allowed} =
             Policy.validate_decision(
               %{
                 "type" => "select_option",
                 "expected_revision" => 7,
                 "locator" => %{"role" => "combobox"},
                 "value" => String.duplicate("x", 1_025)
               },
               context
             )

    assert {:error, :locator_not_allowed} =
             Policy.validate_decision(
               %{
                 "type" => "click",
                 "expected_revision" => 7,
                 "locator" => %{"css" => "#submit"}
               },
               context
             )
  end

  test "telemetry recursively keeps only bounded allowlisted metadata" do
    metadata = %{
      remote_execution_id: "exec-1",
      phase: "researching",
      metadata: %{failure_code: "quota_exceeded", prompt: "NEVER-LOG-THIS"},
      prompt: "NEVER-LOG-THIS",
      error_details: String.duplicate("x", 100_000)
    }

    sanitized = Telemetry.sanitize(metadata)
    encoded = inspect(sanitized)

    assert sanitized == %{
             remote_execution_id: "exec-1",
             phase: "researching",
             metadata: %{failure_code: "quota_exceeded"}
           }

    refute encoded =~ "NEVER-LOG-THIS"
    assert byte_size(encoded) < 1_024
  end
end
