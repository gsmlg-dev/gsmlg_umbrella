defmodule GSMLG.AdminWeb.External.BrowserControlE2ETest do
  @moduledoc """
  Opt-in E2E checks against a deployed central Admin service and real remote node.

  The configured profile must be dedicated to the test and already authenticated
  with Gemini. No prompt, token, response body, or browser state is logged.
  """

  use ExUnit.Case, async: false

  @moduletag external: true
  @moduletag timeout: :infinity
  @terminal_statuses ~w(completed failed cancelled)
  @required_artifacts ~w(report.markdown report.json sources.json screenshot.png)

  setup_all do
    assert required_env!("BROWSER_E2E_CONFIRM_REAL") == "yes",
           "set BROWSER_E2E_CONFIRM_REAL=yes only for the dedicated deployment"

    :ok = ensure_started(:inets)
    :ok = ensure_started(:ssl)

    base_url = required_env!("BROWSER_E2E_CENTRAL_URL")
    validate_base_url!(base_url)

    %{
      base_url: String.trim_trailing(base_url, "/"),
      bearer: required_env!("BROWSER_E2E_ADMIN_BEARER"),
      second_bearer: required_env!("BROWSER_E2E_SECOND_ADMIN_BEARER"),
      node_id: required_env!("BROWSER_E2E_NODE_ID"),
      profile_id: required_env!("BROWSER_E2E_PROFILE_ID"),
      intervention_reason: required_env!("BROWSER_E2E_INTERVENTION_REASON"),
      latency_samples: positive_env!("BROWSER_E2E_LATENCY_SAMPLES", 20),
      timeout_ms: positive_env!("BROWSER_E2E_WORKFLOW_TIMEOUT_MS", 7_200_000)
    }
  end

  test "real Commander session observes and enforces manual lease handoff", ctx do
    session_request = %{
      "node" => ctx.node_id,
      "profile" => ctx.profile_id,
      "mode" => "automation",
      "authorized_origins" => [
        "https://gemini.google.com",
        "https://accounts.google.com"
      ],
      "ttl" => 300_000
    }

    session = json_request!(ctx, :post, "/api/browser/sessions", session_request)

    session_id = Map.fetch!(session, "id")

    on_exit(fn ->
      request!(ctx, :delete, "/api/browser/sessions/#{session_id}", nil, [200, 204, 409])
    end)

    second_actor = %{ctx | bearer: ctx.second_bearer}

    {_status, _headers, conflict_body} =
      request!(second_actor, :post, "/api/browser/sessions", session_request, [409])

    assert {:ok, %{"code" => "profile_busy"}} = JSON.decode(conflict_body)

    observation =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/observe", %{})

    assert is_integer(observation["revision"])
    assert is_binary(observation["url"])

    click_node_id = required_env!("BROWSER_E2E_SAFE_CLICK_NODE_ID")

    assert observation_node_id?(observation, click_node_id),
           "the configured safe click target was absent from the fresh observation"

    action_id = Ecto.UUID.generate()

    action =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/actions", %{
        "action_id" => action_id,
        "expected_revision" => observation["revision"],
        "type" => "click",
        "locator" => %{"node_id" => click_node_id},
        "input" => %{},
        "timeout_ms" => 10_000
      })

    assert action["action_id"] == action_id
    assert is_integer(action["revision"])
    assert action["revision"] > observation["revision"]

    {stale_status, _headers, stale_body} =
      request!(
        ctx,
        :post,
        "/api/browser/sessions/#{session_id}/actions",
        %{
          "action_id" => Ecto.UUID.generate(),
          "expected_revision" => observation["revision"],
          "type" => "click",
          "locator" => %{"node_id" => click_node_id},
          "input" => %{},
          "timeout_ms" => 10_000
        },
        [409]
      )

    assert stale_status == 409
    assert {:ok, %{"code" => "stale_observation"}} = JSON.decode(stale_body)

    acquired =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/manual-acquire", %{})

    assert acquired["mode"] == "manual"
    assert acquired["status"] == "waiting_human"

    released =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/manual-release", %{})

    assert released["mode"] == "automation"
    assert released["status"] == "waiting_human"
    run_failure_injector!("scan_sensitive_logs")
  end

  test "real Deep Research completes with verified downloadable artifacts", ctx do
    run_workflow!(ctx, %{
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "node" => ctx.node_id,
      "profile" => ctx.profile_id,
      "input" => %{
        "prompt" => required_env!("BROWSER_E2E_DEEP_RESEARCH_PROMPT"),
        "output_locale" => System.get_env("BROWSER_E2E_OUTPUT_LOCALE", "en"),
        "research_scope" => "public web sources",
        "required_sections" => ["Summary", "Evidence"],
        "auto_approve_plan" => true
      },
      "idempotency_key" => "external-deep-#{System.unique_integer([:positive])}",
      "output_formats" => @required_artifacts
    })
  end

  test "real inventory, observation, and action latency satisfy P95 targets", ctx do
    assert ctx.latency_samples in 20..100,
           "BROWSER_E2E_LATENCY_SAMPLES must be between 20 and 100"

    session =
      json_request!(ctx, :post, "/api/browser/sessions", %{
        "node" => ctx.node_id,
        "profile" => ctx.profile_id,
        "mode" => "automation",
        "authorized_origins" => [
          "https://gemini.google.com",
          "https://accounts.google.com"
        ],
        "ttl" => 600_000
      })

    session_id = Map.fetch!(session, "id")

    on_exit(fn ->
      request!(ctx, :delete, "/api/browser/sessions/#{session_id}", nil, [200, 204, 409])
    end)

    measurements =
      Enum.reduce(1..ctx.latency_samples, %{inventory: [], observe: [], action: []}, fn sample,
                                                                                        acc ->
        {_nodes, nodes_ms} = timed(fn -> json_request!(ctx, :get, "/api/browser/nodes", nil) end)

        {_profiles, profiles_ms} =
          timed(fn ->
            json_request!(ctx, :get, "/api/browser/nodes/#{ctx.node_id}/profiles", nil)
          end)

        {observation, observe_ms} =
          timed(fn ->
            json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/observe", %{})
          end)

        {_action, action_ms} =
          timed(fn ->
            json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/actions", %{
              "action_id" => Ecto.UUID.generate(),
              "expected_revision" => observation["revision"],
              "type" => "scroll",
              "input" => %{"delta_x" => 0, "delta_y" => if(rem(sample, 2) == 0, do: -1, else: 1)},
              "timeout_ms" => 10_000
            })
          end)

        %{
          inventory: [max(nodes_ms, profiles_ms) | acc.inventory],
          observe: [observe_ms | acc.observe],
          action: [action_ms | acc.action]
        }
      end)

    assert p95(measurements.inventory) < 2_000
    assert p95(measurements.observe) < 3_000
    assert p95(measurements.action) < 2_000
  end

  test "real YouTube analysis completes with verified downloadable artifacts", ctx do
    run_workflow!(ctx, %{
      "workflow" => "gemini.youtube_analysis",
      "workflow_version" => 1,
      "node" => ctx.node_id,
      "profile" => ctx.profile_id,
      "input" => %{
        "youtube_url" => required_env!("BROWSER_E2E_YOUTUBE_URL"),
        "analysis_profile" => "technical_review",
        "output_locale" => System.get_env("BROWSER_E2E_OUTPUT_LOCALE", "en"),
        "custom_instructions" =>
          "Ground claims in visible video evidence and include timestamps.",
        "use_deep_research" => false
      },
      "idempotency_key" => "external-youtube-#{System.unique_integer([:positive])}",
      "output_formats" => @required_artifacts
    })
  end

  test "real authentication boundary pauses for a human and resumes from fresh state", ctx do
    assert ctx.intervention_reason in ~w(login_required reauth_required passkey_required two_factor_required captcha_required account_warning),
           "BROWSER_E2E_INTERVENTION_REASON must select a human-only authentication boundary"

    run_failure_injector!("prepare_human_intervention")

    job =
      json_request!(
        ctx,
        :post,
        "/api/browser/jobs",
        %{
          "workflow" => "gemini.deep_research",
          "workflow_version" => 1,
          "node" => ctx.node_id,
          "profile" => ctx.profile_id,
          "input" => %{
            "prompt" => required_env!("BROWSER_E2E_INTERVENTION_PROMPT"),
            "output_locale" => System.get_env("BROWSER_E2E_OUTPUT_LOCALE", "en"),
            "research_scope" => "public web sources",
            "required_sections" => ["Summary", "Evidence"],
            "auto_approve_plan" => true
          },
          "idempotency_key" => "external-intervention-#{System.unique_integer([:positive])}",
          "output_formats" => @required_artifacts
        },
        [202]
      )

    job_id = Map.fetch!(job, "id")
    waiting = wait_for_waiting_human!(ctx, job_id)
    session_id = Map.fetch!(waiting, "session_id")

    events_before = job_events!(ctx, job_id)
    required_event = intervention_event!(events_before, "intervention.required")
    required_sequence = required_event["sequence"]

    assert required_event["metadata"]["intervention_reason"] == ctx.intervention_reason or
             required_event["metadata"]["reason"] == ctx.intervention_reason

    acquired =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/manual-acquire", %{})

    assert acquired["mode"] == "manual"
    assert acquired["status"] == "waiting_human"

    run_failure_injector!("complete_human_intervention")

    released =
      json_request!(ctx, :post, "/api/browser/sessions/#{session_id}/manual-release", %{})

    assert released["mode"] == "automation"
    assert released["status"] == "waiting_human"

    resumed = json_request!(ctx, :post, "/api/browser/jobs/#{job_id}/resume", %{})
    refute resumed["status"] in ~w(failed cancelled)

    completed = wait_for_completion!(ctx, job_id)
    assert completed["status"] == "completed"

    events_after = job_events!(ctx, job_id)
    cleared_sequence = intervention_event!(events_after, "intervention.cleared")["sequence"]
    assert cleared_sequence > required_sequence
    verify_artifacts!(ctx, job_id)
    run_failure_injector!("scan_sensitive_logs")
  end

  test "running workflow survives Commander loss, central and Manager restarts, and certificate rotation",
       ctx do
    body = %{
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "node" => ctx.node_id,
      "profile" => ctx.profile_id,
      "input" => %{
        "prompt" => required_env!("BROWSER_E2E_RECOVERY_PROMPT"),
        "output_locale" => System.get_env("BROWSER_E2E_OUTPUT_LOCALE", "en"),
        "research_scope" => "public web sources",
        "required_sections" => ["Summary", "Evidence"],
        "auto_approve_plan" => true
      },
      "idempotency_key" => "external-recovery-#{System.unique_integer([:positive])}",
      "output_formats" => @required_artifacts
    }

    job = json_request!(ctx, :post, "/api/browser/jobs", body, [202])
    job_id = Map.fetch!(job, "id")
    _active = wait_for_active!(ctx, job_id)

    for phase <-
          ~w(commander_disconnect central_restart browser_agent_restart manager_restart certificate_rotate) do
      started = System.monotonic_time(:millisecond)
      run_failure_injector!(phase)

      if phase == "commander_disconnect" do
        assert System.monotonic_time(:millisecond) - started >= 30 * 60 * 1_000,
               "Commander disconnect injection did not hold the connection down for 30 minutes"
      end

      reconciled = json_request!(ctx, :post, "/api/browser/jobs/#{job_id}/reconcile", %{})
      refute reconciled["status"] in ~w(failed cancelled)
    end

    completed = wait_for_completion!(ctx, job_id)
    assert completed["status"] == "completed"
    assert completed["result"]["remote_completed"] == true
    assert completed["result"]["pending_artifact_count"] == 0
    verify_durable_event_history!(ctx, job_id)
    verify_artifacts!(ctx, job_id)
    run_failure_injector!("scan_sensitive_logs")
  end

  defp run_workflow!(ctx, body) do
    job = json_request!(ctx, :post, "/api/browser/jobs", body, [202])
    job_id = Map.fetch!(job, "id")
    completed = wait_for_completion!(ctx, job_id)
    assert completed["status"] == "completed"
    verify_artifacts!(ctx, job_id)
    run_failure_injector!("scan_sensitive_logs")
  end

  defp verify_artifacts!(ctx, job_id) do
    %{"data" => artifacts} =
      json_request!(ctx, :get, "/api/browser/jobs/#{job_id}/artifacts", nil)

    kinds = MapSet.new(artifacts, & &1["kind"])
    assert MapSet.subset?(MapSet.new(@required_artifacts), kinds)

    for artifact <- artifacts do
      assert artifact["status"] == "verified"
      assert is_integer(artifact["size"])
      assert is_binary(artifact["sha256"])

      {content, headers} =
        raw_request!(ctx, :get, "/api/browser/artifacts/#{artifact["id"]}/content", nil)

      assert byte_size(content) == artifact["size"]
      assert Base.encode16(:crypto.hash(:sha256, content), case: :lower) == artifact["sha256"]
      assert header(headers, "cache-control") == "no-store"
      assert header(headers, "x-content-type-options") == "nosniff"
    end
  end

  defp wait_for_active!(ctx, job_id) do
    deadline = System.monotonic_time(:millisecond) + min(ctx.timeout_ms, 120_000)
    poll_active(ctx, job_id, deadline)
  end

  defp poll_active(ctx, job_id, deadline) do
    job = json_request!(ctx, :get, "/api/browser/jobs/#{job_id}", nil)

    cond do
      job["status"] in ~w(accepted running waiting_human collecting_artifacts) ->
        job

      job["status"] in @terminal_statuses ->
        flunk("external recovery workflow terminated before failure injection")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("external recovery workflow did not become active")

      true ->
        Process.sleep(1_000)
        poll_active(ctx, job_id, deadline)
    end
  end

  defp wait_for_completion!(ctx, job_id) do
    deadline = System.monotonic_time(:millisecond) + ctx.timeout_ms
    poll_job(ctx, job_id, deadline)
  end

  defp wait_for_waiting_human!(ctx, job_id) do
    deadline = System.monotonic_time(:millisecond) + ctx.timeout_ms
    poll_waiting_human(ctx, job_id, deadline)
  end

  defp poll_waiting_human(ctx, job_id, deadline) do
    job = json_request!(ctx, :get, "/api/browser/jobs/#{job_id}", nil)

    cond do
      job["status"] == "waiting_human" and is_binary(job["session_id"]) ->
        job

      job["status"] in @terminal_statuses ->
        flunk("external intervention workflow terminated before human handoff")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("external intervention workflow did not request human handoff")

      true ->
        Process.sleep(5_000)
        poll_waiting_human(ctx, job_id, deadline)
    end
  end

  defp job_events!(ctx, job_id) do
    case json_request!(ctx, :get, "/api/browser/jobs/#{job_id}/events?limit=100", nil) do
      %{"data" => events} when is_list(events) -> events
      _invalid -> flunk("external Browser API returned an invalid event collection")
    end
  end

  defp verify_durable_event_history!(ctx, job_id) do
    events = job_events!(ctx, job_id)
    sequences = Enum.map(events, & &1["sequence"])

    assert sequences != []
    assert sequences == Enum.sort(sequences)
    assert sequences == Enum.uniq(sequences)
    assert sequences == Enum.to_list(1..List.last(sequences))
    assert Enum.count(events, &(&1["event"] == "result.available")) == 1
    assert Enum.count(events, &(&1["event"] == "workflow.completed")) == 1
  end

  defp intervention_event!(events, event_name) do
    case Enum.find(events, &(&1["event"] == event_name)) do
      %{"sequence" => sequence} = event when is_integer(sequence) -> event
      _missing -> flunk("external workflow did not emit the required intervention transition")
    end
  end

  defp poll_job(ctx, job_id, deadline) do
    job = json_request!(ctx, :get, "/api/browser/jobs/#{job_id}", nil)

    cond do
      job["status"] == "completed" ->
        job

      job["status"] in @terminal_statuses ->
        flunk("external workflow ended in stable state #{job["status"]}")

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("external workflow did not reach a terminal state before its deadline")

      true ->
        Process.sleep(5_000)
        poll_job(ctx, job_id, deadline)
    end
  end

  defp json_request!(ctx, method, path, body, expected_statuses \\ [200]) do
    {response, _headers} = raw_request!(ctx, method, path, body, expected_statuses)

    case JSON.decode(response) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _invalid -> flunk("external Browser API returned a non-object JSON response")
    end
  end

  defp raw_request!(ctx, method, path, body, expected_statuses \\ [200]) do
    {status, headers, response} = request!(ctx, method, path, body, expected_statuses)
    assert status in expected_statuses
    {response, headers}
  end

  defp request!(ctx, method, path, body, expected_statuses) do
    url = ctx.base_url <> path
    headers = [{~c"authorization", String.to_charlist("Bearer " <> ctx.bearer)}]
    request = http_request(method, url, headers, body)

    case :httpc.request(method, request, http_options(), body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response}} ->
        if status in expected_statuses do
          {status, response_headers, response}
        else
          flunk(
            "external Browser API #{method} #{path} returned #{status} (#{error_code(response)})"
          )
        end

      {:error, _reason} ->
        flunk("external Browser API #{method} #{path} was unreachable")
    end
  end

  defp http_request(method, url, headers, nil) when method in [:get, :delete],
    do: {String.to_charlist(url), headers}

  defp http_request(_method, url, headers, body),
    do: {
      String.to_charlist(url),
      headers,
      ~c"application/json",
      JSON.encode!(body || %{})
    }

  defp http_options do
    ssl =
      case System.get_env("BROWSER_E2E_CA_CERT_FILE") do
        path when is_binary(path) and path != "" ->
          [verify: :verify_peer, cacertfile: String.to_charlist(path)]

        _public_ca ->
          [verify: :verify_peer, cacerts: :public_key.cacerts_get()]
      end

    hostname = [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    [timeout: 30_000, connect_timeout: 5_000, ssl: ssl ++ [customize_hostname_check: hostname]]
  end

  defp validate_base_url!(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil, path: path}
      when is_binary(host) and host != "" and path in [nil, "", "/"] ->
        :ok

      _invalid ->
        raise "BROWSER_E2E_CENTRAL_URL must be a canonical HTTPS origin"
    end
  end

  defp error_code(response) do
    case JSON.decode(response) do
      {:ok, %{"code" => code}} when is_binary(code) -> code
      _other -> "non-json-error"
    end
  end

  defp observation_node_id?(observation, node_id) do
    observation
    |> Map.get("visible_controls", [])
    |> Enum.any?(&(is_map(&1) and &1["node_id"] == node_id))
  end

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {result, System.monotonic_time(:millisecond) - started}
  end

  defp p95(values) do
    sorted = Enum.sort(values)
    index = ceil(length(sorted) * 0.95) - 1
    Enum.at(sorted, index)
  end

  defp header(headers, expected) do
    Enum.find_value(headers, fn {name, value} ->
      if name |> to_string() |> String.downcase() == expected, do: to_string(value)
    end)
  end

  defp run_failure_injector!(phase) do
    path = required_env!("BROWSER_E2E_FAILURE_INJECTOR")

    unless Path.type(path) == :absolute and File.regular?(path) do
      raise "BROWSER_E2E_FAILURE_INJECTOR must name an absolute executable file"
    end

    case System.cmd(path, [phase], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> flunk("external failure injector failed during #{phase}")
    end
  end

  defp required_env!(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _missing -> raise "missing required external E2E environment variable #{name}"
    end
  end

  defp positive_env!(name, default) do
    case System.get_env(name) do
      nil ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _invalid -> raise "#{name} must be a positive integer"
        end
    end
  end

  defp ensure_started(application) do
    case Application.ensure_all_started(application) do
      {:ok, _started} -> :ok
      {:error, _reason} -> raise "could not start external E2E HTTP dependency"
    end
  end
end
