defmodule GSMLG.AdminWeb.BrowserAPI.RequestTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.BrowserAPI.Request

  test "pagination rejects unknown and malformed query parameters" do
    uuid = Ecto.UUID.generate()

    assert {:ok, [limit: 50, after: nil]} = Request.pagination(%{}, :uuid)

    assert {:ok, [limit: 100, after: ^uuid]} =
             Request.pagination(%{"limit" => "100", "after" => uuid}, :uuid)

    assert {:ok, [limit: 2, after: 7]} =
             Request.pagination(%{"limit" => "2", "after" => "7"}, :sequence)

    for params <- [
          %{"limit" => "0"},
          %{"limit" => "101"},
          %{"limit" => "ten"},
          %{"after" => "bad"},
          %{"unknown" => "value"}
        ] do
      assert {:error, "invalid_query"} = Request.pagination(params, :uuid)
    end

    assert {:error, "invalid_query"} = Request.pagination(%{"after" => "0"}, :sequence)
  end

  test "job input uses base workflow plus integer version and has no caller deadline" do
    node_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()

    body = %{
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "node" => node_id,
      "profile" => profile_id,
      "input" => %{
        "prompt" => "Research BEAM",
        "output_locale" => "en-US",
        "research_scope" => "primary sources",
        "required_sections" => ["Summary"],
        "auto_approve_plan" => false
      },
      "idempotency_key" => "job-once",
      "output_formats" => ["report.markdown", "report.json", "sources.json"]
    }

    assert {:ok, attrs} = Request.job(body)
    assert attrs.workflow == "gemini.deep_research"
    assert attrs.workflow_version == 1
    assert attrs.node_id == node_id
    assert attrs.profile_id == profile_id
    refute Map.has_key?(attrs, :deadline_at)

    assert {:error, "invalid_request"} =
             Request.job(Map.put(body, "workflow", "gemini.deep_research/v1"))

    assert {:error, "invalid_request"} = Request.job(Map.put(body, "workflow_version", "1"))
    assert {:error, "invalid_request"} = Request.job(Map.put(body, "deadline_at", "2099-01-01"))
    assert {:error, "invalid_request"} = Request.job(Map.put(body, "extra", true))

    assert {:ok, %{input: %{"auto_approve_plan" => true}}} =
             Request.job(put_in(body, ["input", "auto_approve_plan"], true))

    assert {:error, "invalid_request"} =
             Request.job(put_in(body, ["input", "auto_approve_plan"], "false"))

    assert {:error, "invalid_request"} = Request.job(Map.put(body, "output_formats", []))

    assert {:error, "invalid_request"} =
             Request.job(Map.put(body, "output_formats", ["download"]))

    for invalid_input <- [
          %{body["input"] | "output_locale" => "not_a_locale"},
          Map.put(body["input"], "profile_id", profile_id),
          Map.put(body["input"], "requested_by_actor_id", Ecto.UUID.generate()),
          %{body["input"] | "required_sections" => ["Summary", "Summary"]},
          %{body["input"] | "required_sections" => Enum.map(1..33, &"Section #{&1}")},
          %{body["input"] | "required_sections" => [String.duplicate("x", 129)]}
        ] do
      assert {:error, "invalid_request"} = Request.job(%{body | "input" => invalid_input})
    end
  end

  test "YouTube workflow requires a canonical supported video identity" do
    base = %{
      "workflow" => "gemini.youtube_analysis",
      "workflow_version" => 1,
      "input" => %{
        "youtube_url" => "https://www.youtube.com/watch?v=abcdef",
        "analysis_profile" => "summary",
        "output_locale" => "en-US",
        "custom_instructions" => "",
        "use_deep_research" => false
      },
      "idempotency_key" => "youtube-once",
      "output_formats" => ["report.markdown", "report.json", "sources.json"]
    }

    assert {:ok, _job} = Request.job(base)

    assert {:ok, _job} =
             Request.job(put_in(base, ["input", "youtube_url"], "https://youtu.be/abcdef"))

    for invalid_url <- [
          "https://www.youtube.com/",
          "https://www.youtube.com/watch",
          "https://www.youtube.com/watch?v=short",
          "https://www.youtube.com/watch?v=abcdef#fragment",
          "https://youtu.be/abcdef/more",
          "https://user@youtu.be/abcdef"
        ] do
      assert {:error, "invalid_request"} =
               Request.job(put_in(base, ["input", "youtube_url"], invalid_url))
    end
  end

  test "session input is closed and lowers names and TTL for the facade" do
    node_id = Ecto.UUID.generate()
    profile_id = Ecto.UUID.generate()

    body = %{
      "node" => node_id,
      "profile" => profile_id,
      "mode" => "automation",
      "authorized_origins" => ["https://gemini.google.com", "https://www.youtube.com"],
      "ttl" => 60_000,
      "permissions" => %{"screenshot" => true, "download" => true}
    }

    assert {:ok,
            %{
              node_id: ^node_id,
              profile_id: ^profile_id,
              mode: "automation",
              authorized_origins: [
                "https://gemini.google.com",
                "https://www.youtube.com"
              ],
              ttl_ms: 60_000,
              permissions: %{"screenshot" => true, "download" => true}
            }} = Request.session(body)

    for invalid <- [
          Map.put(body, "session_id", Ecto.UUID.generate()),
          Map.put(body, "ttl", "60000"),
          Map.put(body, "ttl", 86_400_001),
          Map.put(body, "authorized_origins", []),
          Map.put(body, "authorized_origins", ["http://gemini.google.com"]),
          Map.put(body, "authorized_origins", ["https://user@example.com"]),
          Map.put(body, "authorized_origins", ["https://example.com/path"]),
          Map.put(body, "authorized_origins", ["https://example.com:443"]),
          Map.put(body, "authorized_origins", ["https://localhost"]),
          Map.put(body, "permissions", %{"screenshot" => "true"}),
          Map.put(body, "permissions", %{"cookies" => true}),
          Map.put(body, "mode", "shared")
        ] do
      assert {:error, "invalid_request"} = Request.session(invalid)
    end
  end

  test "profile configuration is closed and accepts only canonical HTTPS origins" do
    body = %{
      "enabled" => true,
      "is_default" => true,
      "allowed_origins" => ["https://gemini.google.com", "https://www.youtube.com"]
    }

    assert {:ok,
            %{
              enabled: true,
              is_default: true,
              allowed_origins: ["https://gemini.google.com", "https://www.youtube.com"]
            }} = Request.profile_configuration(body)

    for invalid <- [
          Map.put(body, "extra", true),
          Map.put(body, "enabled", "true"),
          Map.put(body, "is_default", "true"),
          %{body | "enabled" => false, "is_default" => true},
          Map.put(body, "allowed_origins", []),
          Map.put(body, "allowed_origins", ["http://gemini.google.com"]),
          Map.put(body, "allowed_origins", ["https://gemini.google.com/path"]),
          Map.put(body, "allowed_origins", ["https://gemini.google.com?token=secret"]),
          Map.put(body, "allowed_origins", ["https://GEMINI.google.com"]),
          Map.put(body, "allowed_origins", ["https://gemini.google.com:443"]),
          Map.put(body, "allowed_origins", ["https://localhost"]),
          Map.put(body, "allowed_origins", ["https://127.0.0.1"]),
          Map.put(body, "allowed_origins", [
            "https://gemini.google.com",
            "https://gemini.google.com"
          ])
        ] do
      assert {:error, "invalid_request"} = Request.profile_configuration(invalid)
    end
  end

  test "action input is closed and never receives the path session ID" do
    session_id = Ecto.UUID.generate()

    body = %{
      "action_id" => "action-1",
      "expected_revision" => 4,
      "type" => "fill",
      "locator" => %{"role" => "textbox", "accessible_name" => "Prompt"},
      "input" => %{"text" => "safe input"},
      "postcondition" => %{
        "type" => "node_present",
        "locator" => %{"text" => "Submitted"}
      },
      "timeout_ms" => 10_000
    }

    assert {:ok, action} = Request.action(session_id, body)
    assert action.input == %{"text" => "safe input"}
    assert action.locator == %{"role" => "textbox", "accessible_name" => "Prompt"}
    refute Map.has_key?(action, :session_id)

    assert {:error, "invalid_action"} =
             Request.action(session_id, Map.put(body, "session_id", Ecto.UUID.generate()))

    assert {:error, "invalid_action"} =
             Request.action(session_id, put_in(body, ["input", "javascript"], "alert(1)"))

    assert {:error, "invalid_action"} =
             Request.action(session_id, Map.put(body, "raw_cdp_method", "Runtime.evaluate"))

    assert {:error, "invalid_action"} =
             Request.action(session_id, Map.delete(body, "expected_revision"))

    assert {:error, "invalid_action"} =
             Request.action(
               session_id,
               put_in(body, ["locator", "role"], String.duplicate("r", 129))
             )

    for unsafe_attribute <- ~w(aria-label data-testid name data-test id) do
      assert {:error, "invalid_action"} =
               Request.action(
                 session_id,
                 body
                 |> Map.put("type", "click")
                 |> Map.put("locator", %{
                   "attribute" => %{
                     "name" => unsafe_attribute,
                     "value" => "unsafe-contract"
                   }
                 })
                 |> Map.put("input", %{})
               )
    end

    assert {:ok, _action} =
             Request.action(
               session_id,
               body
               |> Map.put("type", "click")
               |> Map.put("locator", %{
                 "attribute" => %{"name" => "aria-controls", "value" => "dialog-1"}
               })
               |> Map.put("input", %{})
             )

    assert {:ok, _action} =
             Request.action(
               session_id,
               body
               |> Map.put("type", "click")
               |> Map.put("locator", %{
                 "attribute" => %{"name" => "type", "value" => "submit"}
               })
               |> Map.put("input", %{})
             )

    navigate =
      body
      |> Map.put("type", "navigate")
      |> Map.delete("locator")
      |> Map.put("input", %{"url" => "https://example.test"})
      |> Map.delete("postcondition")

    assert {:ok, %{input: %{"url" => "https://example.test"}}} =
             Request.action(session_id, navigate)

    assert {:error, "invalid_action"} =
             Request.action(session_id, put_in(navigate, ["input", "url"], "javascript:alert(1)"))
  end

  test "retry requires its own bounded idempotency key and other controls have empty bodies" do
    assert {:ok, %{idempotency_key: "retry-once"}} =
             Request.retry(%{"idempotency_key" => "retry-once"})

    assert {:error, "invalid_request"} = Request.retry(%{})
    assert {:error, "invalid_request"} = Request.retry(%{"idempotency_key" => "", "x" => 1})
    assert :ok = Request.empty(%{})
    assert {:error, "invalid_request"} = Request.empty(%{"unexpected" => true})
  end
end
