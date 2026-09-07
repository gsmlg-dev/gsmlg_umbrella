defmodule GSMLG.AdminWeb.BrowserAuditTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Plug.Conn

  alias GSMLG.AdminWeb.BrowserAudit

  test "audit output contains only bounded scalar allowlist metadata" do
    conn =
      Plug.Test.conn(:post, "/api/browser/jobs")
      |> assign(:actor, %{id: "actor-1"})
      |> put_resp_header("x-request-id", "request-1")

    leaked = "PROMPT-DO-NOT-LOG"
    token = "TOKEN-DO-NOT-LOG"

    previous_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    log =
      capture_log([level: :info], fn ->
        BrowserAudit.record(conn, "create_job", "rejected", %{
          resource_type: "job",
          resource_id: String.duplicate("x", 500),
          error_code: "invalid_request",
          input: %{"prompt" => leaked},
          details: %{authorization: token},
          arbitrary: [leaked, token]
        })
      end)

    assert log =~ "Audit: browser_api"
    assert log =~ "actor-1"
    assert log =~ "create_job"
    assert log =~ "invalid_request"
    refute log =~ leaked
    refute log =~ token
    refute log =~ String.duplicate("x", 201)
    refute log =~ "input="
    refute log =~ "details="
    refute log =~ "arbitrary="
  end
end
