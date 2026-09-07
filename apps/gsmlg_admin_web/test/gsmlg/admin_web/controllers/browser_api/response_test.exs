defmodule GSMLG.AdminWeb.BrowserAPI.ResponseTest do
  use GSMLG.AdminWeb.ConnCase, async: true

  alias GSMLG.AdminWeb.BrowserAPI.Response

  test "maps stable Browser failures to exhaustive six-field HTTP errors", %{conn: conn} do
    cases = [
      {"actor_required", 422, "request", false, "correct_request"},
      {"invalid_request", 422, "request", false, "correct_request"},
      {"invalid_chat_url", 422, "request", false, "correct_request"},
      {"invalid_workflow_input", 422, "workflow", false, "correct_request"},
      {"unsupported_workflow", 422, "workflow", false, "correct_request"},
      {"not_found", 404, "resource", false, nil},
      {"node_not_found", 404, "node", false, nil},
      {"profile_not_found", 404, "profile", false, nil},
      {"profile_busy", 409, "lease", true, "choose_another_profile"},
      {"lease_conflict", 409, "lease", true, "retry"},
      {"node_offline", 503, "transport", true, "retry"},
      {"capability_not_supported", 503, "capability", true, "retry"},
      {"manager_unavailable", 503, "manager", true, "retry"},
      {"rpc_timeout", 504, "transport", true, "reconcile"},
      {"unknown", 503, "transport", true, "reconcile"},
      {"invalid_rpc_response", 503, "transport", false, "reconcile"},
      {"storage_failed", 503, "artifact", true, "retry"},
      {"service_unavailable", 503, "service", true, "contact_administrator"},
      {"profile_disabled", 422, "profile", false, "choose_another_profile"},
      {"node_disabled", 422, "node", false, "choose_another_node"},
      {"job_terminal", 409, "workflow", false, "refresh_state"},
      {"illegal_job_transition", 409, "workflow", false, nil},
      {"artifact_not_verified", 503, "artifact", true, "retry"},
      {"invalid_range", 416, "artifact", false, "correct_request"},
      {"invalid_session_state", 409, "session", false, "refresh_state"},
      {"invalid_job_state", 409, "workflow", false, "refresh_state"},
      {"job_not_bound", 409, "workflow", false, "reconcile"},
      {"invalid_query", 422, "request", false, "correct_request"},
      {"invalid_action", 422, "action", false, "correct_request"},
      {"action_not_allowed", 422, "policy", false, "correct_request"},
      {"navigation_not_allowed", 422, "policy", false, "correct_request"},
      {"action_outcome_unknown", 409, "action", false, "reconcile"},
      {"session_outcome_unknown", 409, "session", false, "reconcile"},
      {"close_outcome_unknown", 409, "session", false, "reconcile"},
      {"max_attempts_exceeded", 409, "workflow", false, "review_job"},
      {"idempotency_conflict", 409, "request", false, "use_new_idempotency_key"},
      {"profile_node_mismatch", 409, "profile", false, "choose_matching_resources"},
      {"session_mismatch", 409, "session", false, "reconcile"},
      {"job_mismatch", 409, "workflow", false, "reconcile"},
      {"execution_mismatch", 409, "workflow", false, "reconcile"},
      {"stale_observation", 409, "action", true, "observe_again"},
      {"conflict", 409, "request", false, "refresh_state"},
      {"operation_failed", 500, "internal", false, "contact_administrator"},
      {"workflow_deadline_exceeded", 504, "workflow", false, nil}
    ]

    for {code, status, class, retryable, human_action} <- cases do
      error = %GSMLG.Browser.Error{
        class: "unsafe",
        code: code,
        message: "unsafe facade message",
        retryable: false,
        human_action: "unsafe",
        details: %{"prompt" => "secret"}
      }

      response = conn |> recycle() |> Response.from_browser(error) |> json_response(status)

      assert MapSet.new(Map.keys(response)) ==
               MapSet.new(~w(class code message retryable human_action details))

      assert response["class"] == class
      assert response["code"] == code
      assert response["retryable"] == retryable
      assert response["human_action"] == human_action
      assert response["details"] == %{}
      refute response["message"] =~ "unsafe"
      refute inspect(response) =~ "secret"
    end
  end

  test "unknown facade codes fail closed without reflecting details", %{conn: conn} do
    response =
      conn
      |> Response.from_browser(%GSMLG.Browser.Error{
        class: "unsafe",
        code: "future_secret_error",
        message: "unsafe",
        retryable: true,
        human_action: "unsafe",
        details: %{token: "x"}
      })
      |> json_response(500)

    assert response == %{
             "class" => "internal",
             "code" => "browser_internal_error",
             "message" => "The Browser operation could not be completed.",
             "retryable" => false,
             "human_action" => nil,
             "details" => %{}
           }
  end
end
