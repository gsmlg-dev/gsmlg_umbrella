defmodule GSMLG.AdminWeb.BrowserAPI.ControllerTest do
  use GSMLG.AdminWeb.ConnCase

  alias GSMLG.Browser.{Artifact, Job, JobEvent, Node, Profile, Session}
  alias GSMLG.CommandPlatform.AgentRegistry
  alias GSMLG.Repo

  setup do
    previous = Application.get_env(:gsmlg_browser, :enabled)
    Application.put_env(:gsmlg_browser, :enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_browser, :enabled),
        else: Application.put_env(:gsmlg_browser, :enabled, previous)
    end)

    :ok
  end

  test "all 25 operations reject malformed public input with the Browser contract", %{conn: conn} do
    conn = authenticated_conn(conn, user_fixture("invalid"))

    requests = [
      {:get, "/api/browser/nodes?unexpected=true", nil},
      {:get, "/api/browser/nodes/not-a-uuid", nil},
      {:get, "/api/browser/nodes/not-a-uuid/profiles", nil},
      {:post, "/api/browser/nodes/not-a-uuid/profiles/sync", %{}},
      {:patch, "/api/browser/profiles/not-a-uuid", %{}},
      {:post, "/api/browser/profiles/not-a-uuid/launch", %{}},
      {:post, "/api/browser/profiles/not-a-uuid/stop", %{}},
      {:post, "/api/browser/sessions", %{}},
      {:get, "/api/browser/sessions/not-a-uuid", nil},
      {:post, "/api/browser/sessions/not-a-uuid/observe", %{}},
      {:post, "/api/browser/sessions/not-a-uuid/actions", %{}},
      {:post, "/api/browser/sessions/not-a-uuid/manual-acquire", %{}},
      {:post, "/api/browser/sessions/not-a-uuid/manual-release", %{}},
      {:delete, "/api/browser/sessions/not-a-uuid", %{}},
      {:post, "/api/browser/jobs", %{}},
      {:get, "/api/browser/jobs?limit=0", nil},
      {:get, "/api/browser/jobs/not-a-uuid", nil},
      {:get, "/api/browser/jobs/not-a-uuid/events", nil},
      {:post, "/api/browser/jobs/not-a-uuid/cancel", %{}},
      {:post, "/api/browser/jobs/not-a-uuid/retry", %{"idempotency_key" => "retry"}},
      {:post, "/api/browser/jobs/not-a-uuid/resume", %{}},
      {:post, "/api/browser/jobs/not-a-uuid/reconcile", %{}},
      {:get, "/api/browser/jobs/not-a-uuid/artifacts", nil},
      {:get, "/api/browser/artifacts/not-a-uuid", nil},
      {:get, "/api/browser/artifacts/not-a-uuid/content", nil}
    ]

    assert length(requests) == 25

    for {method, path, body} <- requests do
      response_conn = dispatch_request(conn |> recycle(), method, path, body)
      response = json_response(response_conn, 422)

      assert MapSet.new(Map.keys(response)) ==
               MapSet.new(~w(class code message retryable human_action details))

      assert response["code"] in ["invalid_request", "invalid_query", "invalid_action"]
      assert response["details"] == %{}
      assert get_resp_header(response_conn, "cache-control") == ["no-store"]
      assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "read controllers whitelist nodes and profiles", %{conn: conn} do
    actor = user_fixture("resources")
    node = node_fixture(%{metadata: %{"region" => "do-not-return"}})
    profile = profile_fixture(node, %{policy: %{"origin" => "do-not-return"}})
    conn = authenticated_conn(conn, actor)

    assert %{"data" => [listed]} = conn |> get("/api/browser/nodes") |> json_response(200)
    assert listed["id"] == node.id
    refute Map.has_key?(listed, "metadata")

    assert %{"id" => node_id} =
             conn |> recycle() |> get("/api/browser/nodes/#{node.id}") |> json_response(200)

    assert node_id == node.id

    assert %{"data" => [listed_profile]} =
             conn
             |> recycle()
             |> get("/api/browser/nodes/#{node.id}/profiles")
             |> json_response(200)

    assert listed_profile["id"] == profile.id
    refute Map.has_key?(listed_profile, "policy")
  end

  test "profile configuration updates enabled, default, and the safe origin allowlist", %{
    conn: conn
  } do
    actor = user_fixture("profile-config")
    node = node_fixture()
    old_default = profile_fixture(node, %{is_default: true})
    profile = profile_fixture(node, %{is_default: false})
    conn = authenticated_conn(conn, actor)

    response =
      conn
      |> patch("/api/browser/profiles/#{profile.id}", %{
        "enabled" => true,
        "is_default" => true,
        "allowed_origins" => ["https://gemini.google.com", "https://www.youtube.com"]
      })
      |> json_response(200)

    assert response == %{
             "id" => profile.id,
             "node_id" => node.id,
             "external_id" => profile.external_id,
             "name" => profile.name,
             "backend" => profile.backend,
             "enabled" => true,
             "is_default" => true,
             "runtime_status" => "stopped",
             "automation_status" => "available",
             "locale" => nil,
             "timezone" => nil,
             "screen" => %{},
             "allowed_origins" => [
               "https://gemini.google.com",
               "https://www.youtube.com"
             ],
             "last_seen_at" => nil,
             "error_code" => nil
           }

    refute Repo.get!(Profile, old_default.id).is_default
    assert Repo.get!(Profile, profile.id).is_default
  end

  test "session, job, event, and artifact reads enforce actor ownership", %{conn: conn} do
    owner = user_fixture("owner")
    outsider = user_fixture("outsider")
    node = node_fixture()
    profile = profile_fixture(node)
    session = session_fixture(owner, node, profile)

    job =
      owner
      |> job_fixture(node, profile, session)
      |> Job.transition_changeset(%{
        result: %{
          "last_sequence" => 3,
          "artifact_count" => 1,
          "pending_artifact_count" => 0,
          "remote_completed" => true,
          "content" => "must-not-return"
        }
      })
      |> Repo.update!()

    event = event_fixture(job)
    artifact = artifact_fixture(job, "owned artifact")
    session_artifact = session_artifact_fixture(session, "png")

    owner_conn = authenticated_conn(conn, owner)

    assert %{"id" => session_id} =
             owner_conn |> get("/api/browser/sessions/#{session.id}") |> json_response(200)

    assert session_id == session.id

    job_response =
      owner_conn |> recycle() |> get("/api/browser/jobs/#{job.id}") |> json_response(200)

    assert %{
             "id" => job_id,
             "result_available" => true,
             "result" => %{
               "last_sequence" => 3,
               "artifact_count" => 1,
               "pending_artifact_count" => 0,
               "remote_completed" => true
             }
           } = job_response

    assert job_id == job.id
    refute inspect(job_response) =~ "must-not-return"

    assert %{"data" => [%{"id" => event_id}], "page" => %{"limit" => 50}} =
             owner_conn
             |> recycle()
             |> get("/api/browser/jobs/#{job.id}/events")
             |> json_response(200)

    assert event_id == event.id

    assert %{"data" => [%{"id" => artifact_id}], "page" => %{"limit" => 50}} =
             owner_conn
             |> recycle()
             |> get("/api/browser/jobs/#{job.id}/artifacts")
             |> json_response(200)

    assert artifact_id == artifact.id

    assert %{"id" => session_artifact_id, "session_id" => session_id} =
             session_artifact_json =
             owner_conn
             |> recycle()
             |> get("/api/browser/artifacts/#{session_artifact.id}")
             |> json_response(200)

    assert session_artifact_id == session_artifact.id
    assert session_id == session.id
    refute Map.has_key?(session_artifact_json, "job_id")

    session_content =
      owner_conn
      |> recycle()
      |> get("/api/browser/artifacts/#{session_artifact.id}/content")

    assert session_content.status == 200
    assert session_content.resp_body == "png"
    refute inspect(session_content.resp_headers) =~ "remote_session_id"

    assert %{"id" => artifact_id} =
             owner_conn
             |> recycle()
             |> get("/api/browser/artifacts/#{artifact.id}")
             |> json_response(200)

    assert artifact_id == artifact.id

    outsider_conn = authenticated_conn(conn |> recycle(), outsider)

    for path <- [
          "/api/browser/sessions/#{session.id}",
          "/api/browser/jobs/#{job.id}",
          "/api/browser/jobs/#{job.id}/events",
          "/api/browser/jobs/#{job.id}/artifacts",
          "/api/browser/artifacts/#{artifact.id}",
          "/api/browser/artifacts/#{artifact.id}/content",
          "/api/browser/artifacts/#{session_artifact.id}",
          "/api/browser/artifacts/#{session_artifact.id}/content"
        ] do
      response = outsider_conn |> recycle() |> get(path) |> json_response(404)
      assert response["code"] == "not_found"
      refute inspect(response) =~ owner.email
    end
  end

  test "verified artifact content streams full and range responses without stored metadata", %{
    conn: conn
  } do
    owner = user_fixture("download")
    node = node_fixture()
    profile = profile_fixture(node)
    job = job_fixture(owner, node, profile)
    content = String.duplicate("0123456789", 8_000)
    artifact = artifact_fixture(job, content)
    conn = authenticated_conn(conn, owner)

    full = get(conn, "/api/browser/artifacts/#{artifact.id}/content")
    assert full.status == 200
    assert full.resp_body == content
    assert get_resp_header(full, "content-type") == ["text/markdown"]
    assert get_resp_header(full, "content-disposition") |> hd() =~ "attachment"
    assert get_resp_header(full, "cache-control") == ["no-store"]
    assert get_resp_header(full, "x-content-type-options") == ["nosniff"]

    range =
      conn
      |> recycle()
      |> put_req_header("range", "bytes=10-19")
      |> get("/api/browser/artifacts/#{artifact.id}/content")

    assert range.status == 206
    assert range.resp_body == binary_part(content, 10, 10)
    assert get_resp_header(range, "content-range") == ["bytes 10-19/#{byte_size(content)}"]

    invalid =
      conn
      |> recycle()
      |> put_req_header("range", "bytes=999999-1000000")
      |> get("/api/browser/artifacts/#{artifact.id}/content")

    assert %{"code" => "invalid_range"} = json_response(invalid, 416)
    assert get_resp_header(invalid, "content-range") == ["bytes */#{byte_size(content)}"]
  end

  test "job creation uses server deadline and actor-scoped idempotent replay", %{conn: conn} do
    owner = user_fixture("create-job")
    node = node_fixture()
    profile = profile_fixture(node)

    agent_pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    connection_id = {:test, make_ref()}

    {:ok, generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        agent_pid,
        %{capabilities: [%{id: "browser.control", version: 1}]},
        connection_id
      )

    on_exit(fn ->
      AgentRegistry.unregister_agent(node.commander_id, agent_pid, generation)
      send(agent_pid, :stop)
    end)

    body = %{
      "workflow" => "gemini.deep_research",
      "workflow_version" => 1,
      "node" => node.id,
      "profile" => profile.id,
      "input" => %{
        "prompt" => "Research the BEAM scheduler",
        "output_locale" => "en-US",
        "research_scope" => "primary sources",
        "required_sections" => ["Summary"],
        "auto_approve_plan" => false
      },
      "idempotency_key" => "create-job-once",
      "output_formats" => ["report.markdown", "report.json", "sources.json"]
    }

    conn = authenticated_conn(conn, owner)
    created_conn = post(conn, "/api/browser/jobs", body)
    created = json_response(created_conn, 202)

    assert created["status"] == "queued"
    assert is_binary(created["deadline_at"])
    refute Map.has_key?(created, "input")
    refute Map.has_key?(created, "idempotency_key")

    replayed = conn |> recycle() |> post("/api/browser/jobs", body) |> json_response(202)
    assert replayed["id"] == created["id"]

    conflict_body = put_in(body, ["input", "prompt"], "Different input")
    conflict = conn |> recycle() |> post("/api/browser/jobs", conflict_body) |> json_response(409)
    assert conflict["code"] == "idempotency_conflict"
  end

  test "jobs, events, and artifacts use typed forward cursors", %{conn: conn} do
    owner = user_fixture("pagination")
    node = node_fixture()
    profile = profile_fixture(node)
    jobs = Enum.map(1..3, fn _index -> job_fixture(owner, node, profile) end)
    [first_job, second_job | _rest] = Enum.sort_by(jobs, & &1.id)
    event_fixture(first_job, 1)
    event_fixture(first_job, 2)
    artifacts = Enum.map(1..2, fn index -> artifact_fixture(first_job, "artifact-#{index}") end)
    [first_artifact, second_artifact] = Enum.sort_by(artifacts, & &1.id)
    conn = authenticated_conn(conn, owner)

    assert %{
             "data" => [%{"id" => first_id}],
             "page" => %{"limit" => 1, "next_after" => first_id}
           } = conn |> get("/api/browser/jobs?limit=1") |> json_response(200)

    assert first_id == first_job.id

    assert %{"data" => [%{"id" => second_id}]} =
             conn
             |> recycle()
             |> get("/api/browser/jobs?limit=1&after=#{first_id}")
             |> json_response(200)

    assert second_id == second_job.id

    assert %{"data" => [%{"sequence" => 2}]} =
             conn
             |> recycle()
             |> get("/api/browser/jobs/#{first_job.id}/events?limit=1&after=1")
             |> json_response(200)

    assert %{"data" => [%{"id" => artifact_id}]} =
             conn
             |> recycle()
             |> get(
               "/api/browser/jobs/#{first_job.id}/artifacts?limit=1&after=#{first_artifact.id}"
             )
             |> json_response(200)

    assert artifact_id == second_artifact.id
  end

  test "unverified artifacts cannot be downloaded", %{conn: conn} do
    owner = user_fixture("unverified")
    node = node_fixture()
    profile = profile_fixture(node)
    job = job_fixture(owner, node, profile)

    artifact =
      %Artifact{}
      |> Artifact.manifest_changeset(%{
        id: Ecto.UUID.generate(),
        job_id: job.id,
        kind: "report.markdown",
        mime: "text/markdown",
        filename: "pending.md",
        size: 4,
        sha256: :crypto.hash(:sha256, "body") |> Base.encode16(case: :lower),
        transfer_mode: "remote_pending",
        status: "pending",
        ack_status: "not_ready"
      })
      |> Repo.insert!()

    response_conn =
      conn
      |> authenticated_conn(owner)
      |> get("/api/browser/artifacts/#{artifact.id}/content")

    response = json_response(response_conn, 503)
    assert response["code"] == "artifact_not_verified"
    assert response["details"] == %{}
    assert get_resp_header(response_conn, "cache-control") == ["no-store"]
    assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)
  defp dispatch_request(conn, :delete, path, body), do: delete(conn, path, body)

  defp authenticated_conn(conn, user) do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp user_fixture(suffix) do
    GSMLG.AccountsFixtures.user_fixture(%{
      email: "browser-#{suffix}@example.test",
      username: "browser_#{suffix}"
    })
  end

  defp node_fixture(attrs \\ %{}) do
    defaults = %{
      commander_id: "commander-#{System.unique_integer([:positive])}",
      enabled: true,
      default_backend: "cloak_browser",
      status: "offline"
    }

    %Node{} |> Node.changeset(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  defp profile_fixture(node, attrs \\ %{}) do
    defaults = %{
      node_id: node.id,
      external_id: "profile-#{System.unique_integer([:positive])}",
      name: "Research",
      backend: "cloak_browser",
      runtime_status: "stopped",
      automation_status: "available"
    }

    %Profile{} |> Profile.changeset(Map.merge(defaults, attrs)) |> Repo.insert!()
  end

  defp session_fixture(owner, node, profile) do
    %Session{}
    |> Session.changeset(%{
      node_id: node.id,
      profile_id: profile.id,
      mode: "automation",
      status: "ready",
      owner_actor_id: owner.id,
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()
  end

  defp job_fixture(owner, node, profile, session \\ nil) do
    %Job{}
    |> Job.create_changeset(%{
      node_id: node.id,
      profile_id: profile.id,
      session_id: session && session.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      status: "running",
      input: %{
        "prompt" => "private prompt",
        "output_locale" => "en-US",
        "research_scope" => "primary sources",
        "required_sections" => ["Summary"],
        "auto_approve_plan" => false
      },
      output_formats: ["report.markdown", "report.json", "sources.json"],
      idempotency_key: "job-#{System.unique_integer([:positive])}",
      requested_by_actor_id: owner.id,
      deadline_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()
  end

  defp event_fixture(job, sequence \\ 1) do
    %JobEvent{}
    |> JobEvent.changeset(%{
      job_id: job.id,
      remote_execution_id: Ecto.UUID.generate(),
      sequence: sequence,
      event: "workflow.started",
      phase: "inspect_auth",
      metadata: %{"central_job_id" => job.id},
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp artifact_fixture(job, content) do
    %Artifact{}
    |> Artifact.manifest_changeset(%{
      id: Ecto.UUID.generate(),
      job_id: job.id,
      kind: "report.markdown",
      mime: "text/markdown",
      filename: "artifact.md",
      size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      transfer_mode: "inline",
      status: "verified",
      storage_type: "inline",
      inline_content: content,
      verified_at: DateTime.utc_now(),
      ack_status: "acked"
    })
    |> Repo.insert!()
  end

  defp session_artifact_fixture(session, content) do
    %Artifact{}
    |> Artifact.manifest_changeset(%{
      id: Ecto.UUID.generate(),
      session_id: session.id,
      kind: "screenshot.png",
      mime: "image/png",
      filename: "screenshot.png",
      size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      transfer_mode: "inline",
      status: "verified",
      storage_type: "inline",
      inline_content: content,
      verified_at: DateTime.utc_now(),
      ack_status: "acked",
      metadata: %{"remote_session_id" => Ecto.UUID.generate()}
    })
    |> Repo.insert!()
  end
end
