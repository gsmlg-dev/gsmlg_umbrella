defmodule GSMLG.BrowserAgent.SafeBrowserTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{Journal, Locator, OriginPolicy, ProfileLeaseServer, SafeBrowser}
  alias GSMLG.Commander.Protocol.ArtifactManifest

  @central_session_id "523e4567-e89b-42d3-a456-426614174000"

  defmodule Adapter do
    @behaviour GSMLG.BrowserAgent.SafeBrowser.Adapter

    @impl true
    def observe(agent, timeout) do
      Agent.get_and_update(agent, fn
        %{observations: [{:error, reason} | rest]} = state ->
          {{:error, reason},
           state
           |> Map.put(:observations, rest)
           |> record_observe(timeout)}

        %{observations: [next | rest]} = state ->
          {{:ok, next}, state |> Map.put(:observations, rest) |> record_observe(timeout)}

        state ->
          {{:error, :cdp_disconnected}, record_observe(state, timeout)}
      end)
    end

    @impl true
    def execute(agent, action, target, timeout) do
      Agent.get_and_update(agent, fn state ->
        result = Map.get(state, :execute_result, {:ok, %{}})

        state =
          state
          |> update_in([:executions], &[{action.type, target} | &1])
          |> Map.update(:execute_timeouts, [timeout], &[timeout | &1])
          |> Map.update(:now, 0, &(&1 + Map.get(state, :execute_advance_ms, 0)))

        {result, state}
      end)
    end

    @impl true
    def observation_epoch(agent), do: {:ok, Agent.get(agent, & &1.epoch)}

    @impl true
    def resolve_locator(agent, %Locator{type: :css} = locator, _timeout) do
      Agent.get_and_update(agent, fn
        %{css_resolutions: [next | rest]} = state ->
          {next,
           %{
             state
             | css_resolutions: rest,
               resolved_locators: [locator | state.resolved_locators]
           }}

        state ->
          {{:error, :action_target_not_found}, state}
      end)
    end

    @impl true
    def cleanup_output(_agent, {:assert_promoted, test_pid, journal, artifact_id}) do
      send(
        test_pid,
        {:cleanup_after_promotion,
         GSMLG.BrowserAgent.Journal.get(journal, :artifact_outbox, artifact_id)}
      )

      :ok
    end

    def cleanup_output(_agent, :cleanup), do: :ok

    defp record_observe(state, timeout) do
      state
      |> Map.update!(:observe_count, &(&1 + 1))
      |> Map.update(:observe_timeouts, [timeout], &[timeout | &1])
      |> Map.update(:now, 0, &(&1 + Map.get(state, :observe_advance_ms, 0)))
    end
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dets_name = String.to_atom("safe_browser_#{System.unique_integer([:positive])}")

    {:ok, journal} =
      Journal.start_link(
        name: nil,
        path: Path.join(tmp_dir, "safe-browser.dets"),
        dets_name: dets_name
      )

    {:ok, leases} = ProfileLeaseServer.start_link(name: nil, journal: journal)

    {:ok, lease} =
      ProfileLeaseServer.acquire(leases, "profile-1", :automation, "session-1",
        lease_id: "lease-1",
        mode: :automation,
        now: ~U[2026-09-05 00:00:00Z],
        ttl_ms: 60_000
      )

    {:ok, policy} =
      OriginPolicy.new(
        allowed_origins: ["https://gemini.google.com"],
        allowed_schemes: ["https"]
      )

    {:ok, adapter_state} =
      Agent.start_link(fn ->
        %{
          observations: [],
          executions: [],
          observe_count: 0,
          execute_result: {:ok, %{}},
          epoch: 0,
          css_resolutions: [],
          resolved_locators: []
        }
      end)

    clock = fn -> ~U[2026-09-05 00:00:01Z] end

    {:ok, browser} =
      SafeBrowser.new(
        session_id: "session-1",
        central_session_id: @central_session_id,
        profile_id: "profile-1",
        lease_id: lease.lease_id,
        journal: journal,
        lease_server: leases,
        client: adapter_state,
        adapter: Adapter,
        origin_policy: policy,
        resolver: fn _host -> {:ok, [{8, 8, 8, 8}]} end,
        clock: clock,
        observation_ttl_ms: 10_000,
        max_observation_nodes: 100,
        max_observation_depth: 8,
        max_observation_bytes: 32_000,
        state_dir: tmp_dir,
        max_artifact_bytes: 4
      )

    on_exit(fn ->
      if Process.alive?(adapter_state), do: Agent.stop(adapter_state)
      if Process.alive?(leases), do: GenServer.stop(leases)
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(dets_name)
    end)

    %{
      browser: browser,
      adapter_state: adapter_state,
      journal: journal,
      leases: leases
    }
  end

  test "journals, validates, executes, observes, and verifies in durable order", context do
    enqueue(context.adapter_state, [observation("Initial"), observation("Research complete")])

    assert {:ok, %{"revision" => 1}, browser} = SafeBrowser.observe(context.browser)

    action =
      action("click", %{
        "locator" => %{"role" => "button", "accessible_name" => "Submit"},
        "preconditions" => [
          %{"type" => "origin_is", "value" => "https://gemini.google.com"}
        ],
        "postconditions" => [%{"type" => "title_contains", "value" => "complete"}]
      })

    assert {:ok, %{"action_id" => "action-1", "revision" => 2}, _browser} =
             SafeBrowser.execute(browser, action)

    assert [{:click, %{"backend_node_id" => 41}}] = executions(context.adapter_state)

    assert {:ok,
            %{
              status: :completed,
              history: [:received, :journaled, :validating, :executing, :verifying, :completed]
            }} = Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "preserves a stale document capture as a stale observation error", context do
    enqueue(context.adapter_state, [{:error, :stale_observation}])

    assert {:error, :stale_observation, browser} = SafeBrowser.observe(context.browser)
    assert browser.observation == nil
    assert browser.revision == 0
  end

  test "rejects stale or expired observations and lease conflicts before side effects", context do
    enqueue(context.adapter_state, [observation("Initial")])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)

    stale = action("click", %{"locator" => %{"node_id" => "submit"}, "expected_revision" => 0})
    assert {:error, :stale_observation, browser} = SafeBrowser.execute(browser, stale)
    assert [] = executions(context.adapter_state)

    assert {:ok, %{status: :rejected, history: history}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})

    assert history == [:received, :journaled, :validating, :rejected]

    assert :ok = ProfileLeaseServer.release(context.leases, "profile-1", "lease-1")

    assert {:ok, _other} =
             ProfileLeaseServer.acquire(context.leases, "profile-1", :automation, "other-session",
               lease_id: "other-lease",
               now: ~U[2026-09-05 00:00:01Z],
               ttl_ms: 60_000
             )

    lease_conflict = %{stale | "action_id" => "action-2", "expected_revision" => 1}
    assert {:error, :lease_conflict, _browser} = SafeBrowser.execute(browser, lease_conflict)
    assert [] = executions(context.adapter_state)

    expired = %{browser | clock: fn -> ~U[2026-09-05 00:01:00Z] end}
    expired_action = %{stale | "action_id" => "action-3", "expected_revision" => 1}
    assert {:error, :stale_observation, _browser} = SafeBrowser.execute(expired, expired_action)
  end

  test "an expired authoritative lease cannot observe or act", context do
    lease_expired = %{context.browser | clock: fn -> ~U[2026-09-05 00:01:00Z] end}
    assert {:error, :lease_conflict, _browser} = SafeBrowser.observe(lease_expired)
    assert [] = executions(context.adapter_state)
  end

  test "rejects an asynchronously invalidated document revision before side effects", context do
    enqueue(context.adapter_state, [observation("Initial")])
    assert {:ok, %{"revision" => 1}, browser} = SafeBrowser.observe(context.browser)
    Agent.update(context.adapter_state, &Map.update!(&1, :epoch, fn epoch -> epoch + 1 end))

    click = action("click", %{"locator" => %{"node_id" => "submit"}})
    assert {:error, :stale_observation, _browser} = SafeBrowser.execute(browser, click)
    assert [] = executions(context.adapter_state)

    assert {:ok, %{status: :rejected, error_code: :stale_observation}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "revalidates the observed origin after navigation redirects", context do
    enqueue(context.adapter_state, [
      observation("Initial"),
      observation("Redirected", "https://evil.example/")
    ])

    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)

    navigate =
      action("navigate", %{
        "url" => "https://gemini.google.com/start",
        "postconditions" => [
          %{"type" => "origin_is", "value" => "https://gemini.google.com"}
        ]
      })

    assert {:error, :action_outcome_unknown, _browser} = SafeBrowser.execute(browser, navigate)
    assert [{:navigate, nil}] = executions(context.adapter_state)

    assert {:ok, %{status: :outcome_unknown, error_code: :action_outcome_unknown}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "an invalid post-effect observation is durable outcome_unknown", context do
    enqueue(context.adapter_state, [observation("Initial"), %{"invalid" => "observation"}])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)
    click = action("click", %{"locator" => %{"node_id" => "submit"}})

    assert {:error, :action_outcome_unknown, _browser} = SafeBrowser.execute(browser, click)
    assert [{:click, _target}] = executions(context.adapter_state)

    assert {:ok, %{status: :outcome_unknown, retryable: false}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "uses one action deadline and makes post-dispatch expiry outcome unknown", context do
    enqueue(context.adapter_state, [observation("Initial"), observation("Complete")])

    browser = %{
      context.browser
      | monotonic_ms: fn -> Agent.get(context.adapter_state, &Map.get(&1, :now, 0)) end
    }

    assert {:ok, _observation, browser} = SafeBrowser.observe(browser)

    Agent.update(context.adapter_state, fn state ->
      state
      |> Map.put(:execute_advance_ms, 4)
      |> Map.put(:observe_advance_ms, 7)
    end)

    timed_action =
      action("click", %{
        "locator" => %{"node_id" => "submit"},
        "timeout_ms" => 10
      })

    assert {:error, :action_outcome_unknown, _browser} =
             SafeBrowser.execute(browser, timed_action)

    state = Agent.get(context.adapter_state, & &1)
    assert [10] = Enum.reverse(state.execute_timeouts)
    assert [5_000, 6] = Enum.reverse(state.observe_timeouts)

    assert {:ok, %{status: :outcome_unknown, retryable: false}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "bounds durable action transition history across retries", context do
    enqueue(context.adapter_state, [observation("Initial"), observation("Complete")])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)

    click = action("click", %{"locator" => %{"node_id" => "submit"}})

    fingerprint =
      click
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    assert :ok =
             Journal.put(context.journal, :pending_action, {"session-1", "action-1"}, %{
               action_id: "action-1",
               session_id: "session-1",
               fingerprint: fingerprint,
               status: :failed,
               retryable: true,
               retention_reserved_bytes: 1_000_000,
               history: List.duplicate(:failed, 100)
             })

    assert {:ok, _result, _browser} = SafeBrowser.execute(browser, click)

    assert {:ok, %{status: :completed, history: history}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})

    assert length(history) <= 16
    assert List.last(history) == :completed
  end

  test "a non-navigation action requires an authorized observation before side effects",
       context do
    permitted = %{context.browser | allow_screenshots: true}

    set_execute_result(
      context.adapter_state,
      {:ok, {:artifact, "screenshot", "image/png", "png"}}
    )

    screenshot = action("screenshot", %{"expected_revision" => nil})
    assert {:error, :stale_observation, _browser} = SafeBrowser.execute(permitted, screenshot)
    assert [] = executions(context.adapter_state)

    assert :error =
             Journal.get(context.journal, :artifact_outbox, "session-1:action-1:screenshot")
  end

  test "postcondition failure retains the newer revision but makes the outcome unknown",
       context do
    enqueue(context.adapter_state, [observation("Initial"), observation("Changed")])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)

    click =
      action("click", %{
        "locator" => %{"node_id" => "submit"},
        "postconditions" => [%{"type" => "title_contains", "value" => "Missing"}]
      })

    assert {:error, :action_outcome_unknown, changed} = SafeBrowser.execute(browser, click)
    assert changed.revision == 2
    assert changed.observation["title"] == "Changed"

    assert {:ok, %{status: :outcome_unknown, retryable: false}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})

    stale = %{click | "action_id" => "stale", "postconditions" => []}
    assert {:error, :stale_observation, _browser} = SafeBrowser.execute(changed, stale)
    assert length(executions(context.adapter_state)) == 1
  end

  test "a CDP protocol error after dispatch is durable outcome_unknown", context do
    enqueue(context.adapter_state, [observation("Initial")])
    set_execute_result(context.adapter_state, {:error, {:cdp_error, -32_000}})
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)
    click = action("click", %{"locator" => %{"node_id" => "submit"}})

    assert {:error, :action_outcome_unknown, _browser} = SafeBrowser.execute(browser, click)

    assert {:ok, %{status: :outcome_unknown, retryable: false}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})
  end

  test "disconnect ambiguity is durable, returned as unknown, and never blindly retried",
       context do
    enqueue(context.adapter_state, [observation("Initial")])
    set_execute_result(context.adapter_state, {:error, :cdp_disconnected})
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)
    action = action("click", %{"locator" => %{"node_id" => "submit"}})

    assert {:error, :action_outcome_unknown, browser} = SafeBrowser.execute(browser, action)
    assert [{:click, _target}] = executions(context.adapter_state)

    assert {:ok, %{status: :outcome_unknown, history: history}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-1"})

    assert history == [:received, :journaled, :validating, :executing, :outcome_unknown]

    assert {:error, :action_outcome_unknown, ^browser} = SafeBrowser.execute(browser, action)
    assert [_one_execution] = executions(context.adapter_state)
  end

  test "recovery distinguishes pre-dispatch and possibly-dispatched actions", context do
    validating = %{
      action_id: "action-safe",
      session_id: "session-1",
      fingerprint: "a",
      status: :validating,
      history: [:received, :journaled, :validating]
    }

    executing = %{
      action_id: "action-unknown",
      session_id: "session-1",
      fingerprint: "b",
      status: :executing,
      history: [:received, :journaled, :validating, :executing]
    }

    :ok = Journal.put(context.journal, :pending_action, {"session-1", "action-safe"}, validating)

    :ok =
      Journal.put(context.journal, :pending_action, {"session-1", "action-unknown"}, executing)

    assert :ok = SafeBrowser.recover_actions(context.journal, "session-1")

    assert {:ok, %{status: :failed, retryable: true, error_code: :action_not_executed}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-safe"})

    assert {:ok,
            %{status: :outcome_unknown, retryable: false, error_code: :action_outcome_unknown}} =
             Journal.get(context.journal, :pending_action, {"session-1", "action-unknown"})
  end

  test "recovery permits the same action id only when dispatch was provably not attempted",
       context do
    action =
      action("navigate", %{
        "expected_revision" => nil,
        "url" => "https://gemini.google.com/next"
      })

    fingerprint =
      action
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    validating = %{
      action_id: "action-1",
      session_id: "session-1",
      fingerprint: fingerprint,
      status: :validating,
      history: [:received, :journaled, :validating]
    }

    :ok = Journal.put(context.journal, :pending_action, {"session-1", "action-1"}, validating)
    assert :ok = SafeBrowser.recover_actions(context.journal, "session-1")

    enqueue(context.adapter_state, [observation("After retry")])

    assert {:ok, %{"revision" => 1}, _browser} =
             SafeBrowser.execute(context.browser, action)

    assert [{:navigate, nil}] = executions(context.adapter_state)
  end

  test "screenshots require permission and return only bounded durable manifests", context do
    enqueue(context.adapter_state, [observation("Initial"), observation("After capture")])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)
    screenshot = action("screenshot", %{})

    assert {:error, :action_not_allowed, _browser} = SafeBrowser.execute(browser, screenshot)
    assert [] = executions(context.adapter_state)

    permitted = %{browser | allow_screenshots: true}
    permitted_screenshot = %{screenshot | "action_id" => "action-permitted"}

    set_execute_result(
      context.adapter_state,
      {:ok, {:artifact, "screenshot", "image/png", "png"}}
    )

    assert {:ok, %{"output" => %{"artifact" => manifest}}, _browser} =
             SafeBrowser.execute(permitted, permitted_screenshot)

    assert manifest["artifact_id"] ==
             GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(
               @central_session_id,
               "action-permitted:screenshot.png"
             )

    assert manifest["session_id"] == @central_session_id
    refute Map.has_key?(manifest, "job_id")
    assert manifest["kind"] == "screenshot.png"
    assert manifest["size"] == 3
    assert manifest["transfer_mode"] == "remote_pending"
    assert manifest["metadata"] == %{"remote_session_id" => "session-1"}

    assert {:ok, %ArtifactManifest{session_id: @central_session_id}} =
             ArtifactManifest.decode(Map.put(manifest, "type", "artifact.manifest"))

    refute JSON.encode!(manifest) =~ "cG5n"

    oversized = %{screenshot | "action_id" => "action-oversized"}
    enqueue(context.adapter_state, [observation("After oversized")])

    set_execute_result(
      context.adapter_state,
      {:ok, {:artifact, "screenshot", "image/png", "12345"}}
    )

    assert {:error, :artifact_too_large, _browser} = SafeBrowser.execute(permitted, oversized)
  end

  test "downloads reauthorize their source and expose only sanitized artifact metadata",
       context do
    enqueue(context.adapter_state, [observation("Initial"), observation("After download")])
    assert {:ok, _observation, browser} = SafeBrowser.observe(context.browser)
    permitted = %{browser | allow_downloads: true}

    set_execute_result(
      context.adapter_state,
      {:ok,
       {:artifact, "download", "application/json", "{}",
        %{
          "source_url" => "https://gemini.google.com/report.json?secret=query",
          "suggested_filename" => "../report🌙.json"
        },
        {:assert_promoted, self(), context.journal,
         GSMLG.BrowserAgent.WorkflowArtifacts.artifact_id(
           @central_session_id,
           "action-1:download"
         )}}}
    )

    download = action("download", %{"locator" => %{"node_id" => "submit"}})

    assert {:ok, %{"output" => %{"artifact" => manifest}}, _browser} =
             SafeBrowser.execute(permitted, download)

    assert manifest["filename"] == "report_.json"
    assert manifest["mime"] == "application/json"
    assert manifest["metadata"]["source_origin"] == "https://gemini.google.com"
    assert manifest["metadata"]["remote_session_id"] == "session-1"
    refute Map.has_key?(manifest["metadata"], "suggested_filename")
    assert manifest["session_id"] == @central_session_id

    assert {:ok, %ArtifactManifest{session_id: @central_session_id}} =
             ArtifactManifest.decode(Map.put(manifest, "type", "artifact.manifest"))

    refute JSON.encode!(manifest) =~ "secret=query"
    refute JSON.encode!(manifest) =~ "report.json?"

    assert_receive {:cleanup_after_promotion, {:ok, %{status: :pending}}}

    enqueue(context.adapter_state, [observation("After rejected download")])

    set_execute_result(
      context.adapter_state,
      {:ok,
       {:artifact, "download", "application/pdf", "pdf",
        %{
          "source_url" => "https://evil.example/report.pdf",
          "suggested_filename" => "report.pdf"
        }, :cleanup}}
    )

    rejected = %{download | "action_id" => "download-rejected"}
    assert {:error, :action_outcome_unknown, _browser} = SafeBrowser.execute(permitted, rejected)

    set_execute_result(context.adapter_state, {:error, :cdp_timeout})
    timed_out = %{download | "action_id" => "download-timeout"}

    assert {:error, :action_outcome_unknown, _browser} =
             SafeBrowser.execute(permitted, timed_out)
  end

  test "wait_for polls bounded observations with a sleeper until its locator appears", context do
    enqueue(context.adapter_state, [
      observation("Initial"),
      observation_without_target("Still loading"),
      observation("Done")
    ])

    {:ok, time} = Agent.start_link(fn -> 0 end)
    test_pid = self()

    browser = %{
      context.browser
      | monotonic_ms: fn -> Agent.get(time, & &1) end,
        sleeper: fn milliseconds ->
          Agent.update(time, &(&1 + milliseconds))
          send(test_pid, {:slept, milliseconds})
        end,
        wait_poll_ms: 10
    }

    assert {:ok, _observation, browser} = SafeBrowser.observe(browser)

    wait =
      action("wait_for", %{
        "locator" => %{"node_id" => "submit"},
        "timeout_ms" => 100
      })

    assert {:ok, %{"revision" => 3}, _browser} = SafeBrowser.execute(browser, wait)
    assert_receive {:slept, 10}
    assert [] = executions(context.adapter_state)
    Agent.stop(time)
  end

  test "wait_for resolves controlled CSS through the adapter when policy enables it", context do
    enqueue(context.adapter_state, [
      observation("Initial"),
      observation_without_target("Still loading"),
      observation("Done")
    ])

    Agent.update(context.adapter_state, fn state ->
      %{
        state
        | css_resolutions: [
            {:error, :action_target_not_found},
            {:ok, %{"backend_node_id" => 41}}
          ]
      }
    end)

    {:ok, time} = Agent.start_link(fn -> 0 end)

    browser = %{
      context.browser
      | allow_css_locator: true,
        monotonic_ms: fn -> Agent.get(time, & &1) end,
        sleeper: fn milliseconds -> Agent.update(time, &(&1 + milliseconds)) end,
        wait_poll_ms: 10
    }

    assert {:ok, _observation, browser} = SafeBrowser.observe(browser)

    wait =
      action("wait_for", %{
        "locator" => %{"css" => "[data-testid=submit]"},
        "timeout_ms" => 100
      })

    assert {:ok, %{"revision" => 3}, _browser} = SafeBrowser.execute(browser, wait)
    assert 2 == length(Agent.get(context.adapter_state, & &1.resolved_locators))
    assert [] = executions(context.adapter_state)
    Agent.stop(time)
  end

  defp action(type, fields) do
    Map.merge(
      %{
        "action_id" => "action-1",
        "session_id" => "session-1",
        "expected_revision" => 1,
        "type" => type,
        "timeout_ms" => 5_000
      },
      fields
    )
  end

  defp observation(title, url \\ "https://gemini.google.com/app") do
    %{
      "url" => url,
      "title" => title,
      "loading_state" => "complete",
      "page_kind" => "document",
      "alerts" => [],
      "nodes" => [
        %{
          "node_id" => "submit",
          "backend_node_id" => 41,
          "role" => "button",
          "name" => "Submit",
          "depth" => 1,
          "visible" => true
        }
      ]
    }
  end

  defp observation_without_target(title) do
    observation(title) |> Map.put("nodes", [])
  end

  defp enqueue(agent, observations) do
    Agent.update(agent, &Map.put(&1, :observations, observations))
  end

  defp set_execute_result(agent, result) do
    Agent.update(agent, &Map.put(&1, :execute_result, result))
  end

  defp executions(agent), do: Agent.get(agent, &Enum.reverse(&1.executions))
end
