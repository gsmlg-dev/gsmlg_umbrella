defmodule GSMLG.AdminWeb.BrowserAPI.Response do
  @moduledoc false

  import Plug.Conn

  alias GSMLG.Browser.Error

  @errors %{
    "not_found" => {404, "resource", "Browser resource not found.", false, nil},
    "profile_not_found" => {404, "profile", "Browser profile not found.", false, nil},
    "node_not_found" => {404, "node", "Browser node not found.", false, nil},
    "profile_busy" =>
      {409, "lease", "The Browser profile is busy.", true, "choose_another_profile"},
    "lease_conflict" =>
      {409, "lease", "The Browser profile lease conflicts with this operation.", true, "retry"},
    "profile_node_mismatch" =>
      {409, "profile", "The Browser profile does not belong to the selected node.", false,
       "choose_matching_resources"},
    "idempotency_conflict" =>
      {409, "request", "The idempotency key was already used for different input.", false,
       "use_new_idempotency_key"},
    "stale_observation" =>
      {409, "action", "The Browser observation is stale.", true, "observe_again"},
    "illegal_job_transition" =>
      {409, "workflow", "The requested job transition is not allowed.", false, nil},
    "invalid_session_state" =>
      {409, "session", "The Browser session is not in a valid state for this operation.", false,
       "refresh_state"},
    "invalid_job_state" =>
      {409, "workflow", "The Browser job is not in a valid state for this operation.", false,
       "refresh_state"},
    "job_terminal" =>
      {409, "workflow", "The Browser job is already terminal.", false, "refresh_state"},
    "job_not_bound" =>
      {409, "workflow", "The Browser job has not been bound to a remote execution.", false,
       "reconcile"},
    "session_mismatch" =>
      {409, "session", "The remote Browser session identity did not match.", false, "reconcile"},
    "job_mismatch" =>
      {409, "workflow", "The remote Browser job identity did not match.", false, "reconcile"},
    "execution_mismatch" =>
      {409, "workflow", "The remote Browser execution identity did not match.", false,
       "reconcile"},
    "conflict" =>
      {409, "request", "The Browser request conflicts with existing state.", false,
       "refresh_state"},
    "actor_required" =>
      {422, "request", "The Browser request is invalid.", false, "correct_request"},
    "invalid_request" =>
      {422, "request", "The Browser request is invalid.", false, "correct_request"},
    "invalid_chat_url" =>
      {422, "request", "The Browser request is invalid.", false, "correct_request"},
    "invalid_query" =>
      {422, "request", "The Browser query is invalid.", false, "correct_request"},
    "invalid_action" =>
      {422, "action", "The Browser action is invalid.", false, "correct_request"},
    "action_not_allowed" =>
      {422, "policy", "The Browser action is not allowed.", false, "correct_request"},
    "action_outcome_unknown" =>
      {409, "action", "The remote Browser action outcome is unknown.", false, "reconcile"},
    "session_outcome_unknown" =>
      {409, "session", "The remote Browser session outcome is unknown.", false, "reconcile"},
    "close_outcome_unknown" =>
      {409, "session", "The remote Browser session close outcome is unknown.", false, "reconcile"},
    "max_attempts_exceeded" =>
      {409, "workflow", "The Browser job retry limit has been reached.", false, "review_job"},
    "navigation_not_allowed" =>
      {422, "policy", "Navigation is not allowed by policy.", false, "correct_request"},
    "profile_disabled" =>
      {422, "profile", "The Browser profile is disabled.", false, "choose_another_profile"},
    "node_disabled" =>
      {422, "node", "The Browser node is disabled.", false, "choose_another_node"},
    "invalid_workflow_input" =>
      {422, "workflow", "The workflow input is invalid.", false, "correct_request"},
    "unsupported_workflow" =>
      {422, "workflow", "The workflow or version is not supported.", false, "correct_request"},
    "invalid_range" =>
      {416, "artifact", "The requested Browser artifact range is invalid.", false,
       "correct_request"},
    "node_offline" => {503, "transport", "The Browser node is offline.", true, "retry"},
    "capability_not_supported" =>
      {503, "capability", "The Browser capability is unavailable.", true, "retry"},
    "manager_unavailable" =>
      {503, "manager", "The Browser manager is unavailable.", true, "retry"},
    "artifact_not_verified" =>
      {503, "artifact", "The Browser artifact is not available for download.", true, "retry"},
    "storage_failed" =>
      {503, "artifact", "The Browser artifact could not be read.", true, "retry"},
    "service_unavailable" =>
      {503, "service", "The Browser service is unavailable.", true, "contact_administrator"},
    "unknown" =>
      {503, "transport", "The outcome of the Browser operation is unknown.", true, "reconcile"},
    "invalid_rpc_response" =>
      {503, "transport", "The Browser node returned an invalid response.", false, "reconcile"},
    "operation_failed" =>
      {500, "internal", "The Browser operation could not be completed.", false,
       "contact_administrator"},
    "workflow_deadline_exceeded" =>
      {504, "workflow", "The workflow deadline was exceeded.", false, nil},
    "rpc_timeout" => {504, "transport", "The Browser operation timed out.", true, "reconcile"}
  }

  def from_browser(conn, %Error{code: code}) do
    case Map.fetch(@errors, code) do
      {:ok, {status, class, message, retryable, human_action}} ->
        error(conn, status, class, code, message, retryable, human_action)

      :error ->
        error(
          conn,
          500,
          "internal",
          "browser_internal_error",
          "The Browser operation could not be completed.",
          false,
          nil
        )
    end
  end

  def json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> security_headers()
    |> send_resp(status, JSON.encode!(body))
  end

  def no_content(conn) do
    conn
    |> security_headers()
    |> send_resp(204, "")
  end

  def error(conn, status, class, code, message, retryable, human_action, details \\ %{}) do
    body = %{
      class: class,
      code: code,
      message: message,
      retryable: retryable,
      human_action: human_action,
      details: details
    }

    conn
    |> put_resp_content_type("application/json")
    |> security_headers()
    |> send_resp(status, JSON.encode!(body))
  end

  def security_headers(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end
end
