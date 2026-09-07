defmodule GSMLG.BrowserAgent.SafeContractsTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Action, Locator, Observation, OriginPolicy, Postcondition}

  describe "origin policy" do
    test "is exact, default-deny, and revalidates redirects" do
      assert {:ok, policy} =
               OriginPolicy.new(
                 allowed_origins: ["https://gemini.google.com", "https://www.youtube.com"],
                 allowed_schemes: ["https"]
               )

      assert {:ok, "https://gemini.google.com"} =
               OriginPolicy.authorize(policy, "https://gemini.google.com/app?q=1")

      for url <- [
            "http://gemini.google.com/",
            "https://evil.example/",
            "javascript:alert(1)",
            "data:text/html,secret",
            "file:///etc/passwd",
            "https://127.0.0.1/admin",
            "https://[::1]/admin",
            "https://localhost/admin",
            "https://service.local/admin",
            "https://10.1.2.3/admin",
            "https://169.254.169.254/latest/meta-data"
          ] do
        assert {:error, :navigation_not_allowed} = OriginPolicy.authorize(policy, url)
      end

      assert {:error, :navigation_not_allowed} =
               OriginPolicy.authorize_redirect(
                 policy,
                 "https://gemini.google.com/start",
                 "https://accounts.google.com/signin"
               )
    end

    test "rejects unsafe allowlist entries and resolved private addresses" do
      assert {:error, :invalid_origin_policy} =
               OriginPolicy.new(allowed_origins: ["https://localhost"])

      assert {:error, :invalid_origin_policy} =
               OriginPolicy.new(allowed_origins: ["https://239.1.2.3"])

      assert {:error, :invalid_origin_policy} =
               OriginPolicy.new(allowed_origins: ["https://[ff02::1]"])

      assert {:ok, policy} = OriginPolicy.new(allowed_origins: ["https://safe.example"])

      assert {:error, :navigation_not_allowed} =
               OriginPolicy.authorize(policy, "https://safe.example/path",
                 resolver: fn "safe.example" -> {:ok, [{192, 168, 1, 10}]} end
               )

      assert {:error, :navigation_not_allowed} =
               OriginPolicy.authorize(policy, "https://safe.example/path",
                 resolver: fn "safe.example" -> {:ok, [:not_an_ip_address]} end
               )
    end
  end

  describe "locators and actions" do
    test "accepts only the finite locator algebra" do
      for {input, type} <- [
            {%{"node_id" => "node-7"}, :node_id},
            {%{"role" => "button", "accessible_name" => "Send"}, :role},
            {%{"label" => "Email"}, :label},
            {%{"placeholder" => "Search"}, :placeholder},
            {%{"text" => "Research"}, :text},
            {%{"attribute" => %{"name" => "aria-controls", "value" => "menu"}}, :attribute},
            {%{"attribute" => %{"name" => "type", "value" => "submit"}}, :attribute}
          ] do
        assert {:ok, %Locator{type: ^type}} = Locator.decode(input)
      end

      assert {:error, :locator_not_allowed} = Locator.decode(%{"css" => "#submit"})

      assert {:ok, %Locator{type: :css}} =
               Locator.decode(%{"css" => "#submit"}, allow_css_locator: true)

      for input <- [
            %{"xpath" => "//button"},
            %{"javascript" => "document.body"},
            %{"cdp_method" => "Runtime.evaluate"},
            %{"cookie" => "session"},
            %{"storage" => "localStorage"},
            %{"x" => 5, "y" => 7},
            %{"role" => "button", "extra" => true},
            %{"attribute" => %{"name" => "data-testid", "value" => "submit"}},
            %{"attribute" => %{"name" => "data-test", "value" => "submit"}},
            %{"attribute" => %{"name" => "id", "value" => "submit"}},
            %{"attribute" => %{"name" => "name", "value" => "submit"}},
            %{"attribute" => %{"name" => "aria-label", "value" => "Submit"}}
          ] do
        assert {:error, :locator_not_allowed} = Locator.decode(input)
      end
    end

    test "accepts exactly the first-version structured actions" do
      base = %{
        "action_id" => "action-1",
        "session_id" => "session-1",
        "expected_revision" => 3,
        "timeout_ms" => 5_000,
        "preconditions" => [%{"type" => "origin_is", "value" => "https://gemini.google.com"}],
        "postconditions" => [%{"type" => "title_contains", "value" => "complete"}]
      }

      actions = [
        {"navigate", %{"url" => "https://gemini.google.com/app"}},
        {"click", %{"locator" => %{"node_id" => "node-1"}}},
        {"focus", %{"locator" => %{"label" => "Prompt"}}},
        {"fill", %{"locator" => %{"label" => "Prompt"}, "text" => "hello"}},
        {"insert_text", %{"locator" => %{"label" => "Prompt"}, "text" => "hello"}},
        {"press_key", %{"key" => "Enter"}},
        {"select_option", %{"locator" => %{"label" => "Mode"}, "value" => "Fast"}},
        {"scroll", %{"delta_x" => 0, "delta_y" => 600}},
        {"wait_for", %{"locator" => %{"text" => "Done"}}},
        {"extract", %{"locator" => %{"role" => "article"}}},
        {"screenshot", %{}},
        {"download", %{"locator" => %{"role" => "link", "accessible_name" => "PDF"}}}
      ]

      for {type, input} <- actions do
        assert {:ok, %Action{type: action_type}} =
                 Action.decode(Map.merge(base, Map.put(input, "type", type)))

        assert Atom.to_string(action_type) == type
      end

      for forbidden <- [
            %{"type" => "evaluate", "javascript" => "fetch('/cookies')"},
            %{"type" => "cdp", "method" => "Network.getAllCookies"},
            %{"type" => "xpath", "xpath" => "//button"},
            %{"type" => "cookies.read"},
            %{"type" => "storage.read"},
            %{"type" => "click", "locator" => %{"x" => 1, "y" => 1}}
          ] do
        assert {:error, :action_not_allowed} = Action.decode(Map.merge(base, forbidden))
      end

      assert {:error, :action_not_allowed} =
               Action.decode(
                 Map.put(
                   base,
                   "preconditions",
                   List.duplicate(%{"type" => "url_is", "value" => "x"}, 9)
                 )
               )

      singular =
        base
        |> Map.delete("preconditions")
        |> Map.delete("postconditions")
        |> Map.put("postcondition", %{"type" => "title_contains", "value" => "complete"})
        |> Map.merge(%{"type" => "screenshot"})

      assert {:ok, %Action{preconditions: [], postconditions: [_one]}} = Action.decode(singular)
    end
  end

  describe "observations and postconditions" do
    test "bounds the semantic tree and always redacts sensitive inputs" do
      raw = %{
        "url" => "https://gemini.google.com/app",
        "title" => "Gemini",
        "loading_state" => "complete",
        "page_kind" => "document",
        "alerts" => ["Signed in"],
        "nodes" =>
          [
            %{
              "node_id" => "root",
              "role" => "document",
              "name" => "Gemini",
              "depth" => 0,
              "visible" => true
            },
            %{
              "node_id" => "password",
              "backend_node_id" => 19,
              "role" => "textbox",
              "name" => "Password",
              "value" => "super-secret",
              "input_type" => "password",
              "depth" => 1,
              "visible" => true
            },
            %{
              "node_id" => "hidden",
              "role" => "button",
              "name" => "Invisible",
              "depth" => 1,
              "visible" => false
            },
            %{
              "node_id" => "too-deep",
              "role" => "button",
              "name" => "Too deep",
              "depth" => 4,
              "visible" => true
            },
            %{
              "node_id" => "negative-depth",
              "role" => "button",
              "name" => "Invalid depth",
              "depth" => -1,
              "visible" => true
            }
          ] ++
            Enum.map(1..20, fn index ->
              %{
                "node_id" => "item-#{index}",
                "backend_node_id" => index + 100,
                "role" => "button",
                "name" => String.duplicate("x", 80),
                "depth" => 1,
                "visible" => true
              }
            end)
      }

      assert {:ok, observation} =
               Observation.build(raw,
                 session_id: "session-1",
                 lease_id: "lease-1",
                 revision: 7,
                 observed_at: ~U[2026-09-05 00:00:00Z],
                 ttl_ms: 10_000,
                 max_nodes: 5,
                 max_depth: 2,
                 max_bytes: 1_600
               )

      assert %{
               "session_id" => "session-1",
               "lease_id" => "lease-1",
               "revision" => 7,
               "origin" => "https://gemini.google.com",
               "expires_at" => "2026-09-05T00:00:10.000Z",
               "semantic_tree" => nodes
             } = observation

      assert length(nodes) <= 5
      assert byte_size(JSON.encode!(observation)) <= 1_600
      refute JSON.encode!(observation) =~ "super-secret"
      refute JSON.encode!(observation) =~ "Invisible"
      refute JSON.encode!(observation) =~ "Too deep"
      refute JSON.encode!(observation) =~ "Invalid depth"

      assert %{"value" => "[REDACTED]"} = Enum.find(nodes, &(&1["node_id"] == "password"))
    end

    test "postconditions are finite and verify against an observation" do
      observation = %{
        "url" => "https://gemini.google.com/app/complete",
        "origin" => "https://gemini.google.com",
        "title" => "Research complete",
        "semantic_tree" => [%{"node_id" => "done", "role" => "status", "name" => "Done"}]
      }

      for condition <- [
            %{"type" => "url_is", "value" => observation["url"]},
            %{"type" => "origin_is", "value" => observation["origin"]},
            %{"type" => "title_contains", "value" => "complete"},
            %{"type" => "node_present", "locator" => %{"node_id" => "done"}},
            %{"type" => "node_absent", "locator" => %{"text" => "Failed"}}
          ] do
        assert {:ok, decoded} = Postcondition.decode(condition)
        assert :ok = Postcondition.verify(decoded, observation)
      end

      assert {:error, :postcondition_not_allowed} =
               Postcondition.decode(%{"type" => "javascript", "source" => "true"})
    end

    test "multibyte limits terminate with valid UTF-8 and malformed input fails closed" do
      opts = [
        session_id: "session-1",
        lease_id: "lease-1",
        revision: 1,
        observed_at: ~U[2026-09-05 00:00:00Z],
        ttl_ms: 10_000,
        max_nodes: 5,
        max_depth: 2,
        max_bytes: 900
      ]

      raw = %{
        "url" => "https://gemini.google.com/app",
        "title" => String.duplicate("🌙", 100),
        "nodes" => [
          %{"node_id" => "emoji", "role" => "button", "name" => String.duplicate("🌙", 400)}
        ]
      }

      task = Task.async(fn -> Observation.build(raw, opts) end)
      result = Task.yield(task, 200) || Task.shutdown(task, :brutal_kill)
      assert {:ok, {:ok, observation}} = result
      assert String.valid?(JSON.encode!(observation))
      assert byte_size(JSON.encode!(observation)) <= 900

      invalid = %{raw | "title" => <<255, 254>>}
      assert {:error, :invalid_observation} = Observation.build(invalid, opts)
    end
  end
end
