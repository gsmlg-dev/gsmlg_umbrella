defmodule GSMLG.AdminWeb.BrowserLiveTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  defmodule ArtifactS3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    Plug.Router.get "/*path" do
      ranges = Plug.Conn.get_req_header(conn, "range")

      if pid = Application.get_env(:gsmlg_storage, :browser_live_artifact_pid) do
        send(pid, {:artifact_s3_get, ranges})
      end

      object = Application.fetch_env!(:gsmlg_storage, :browser_live_artifact_object)
      fail_ranges = Application.get_env(:gsmlg_storage, :browser_live_artifact_fail_ranges, [])

      case ranges do
        ["bytes=" <> range] ->
          full_range = "bytes=" <> range

          if full_range in fail_ranges do
            send_resp(conn, 500, "sensitive upstream storage detail")
          else
            [first, last] = range |> String.split("-", parts: 2) |> Enum.map(&String.to_integer/1)
            send_resp(conn, 206, binary_part(object, first, last - first + 1))
          end
      end
    end

    Plug.Router.match(_, do: send_resp(conn, 404, ""))
  end

  import GSMLG.AccountsFixtures
  import Phoenix.LiveViewTest

  alias GSMLG.Browser.{Artifact, Job, JobEvent, Node, Profile, Session}
  alias GSMLG.CommandPlatform.AgentRegistry
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @secret_key_base String.duplicate("r", 64)

  setup %{conn: conn} do
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])
    browser_config = Application.get_all_env(:gsmlg_browser)

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    Application.put_env(:gsmlg_browser, :enabled, true)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> Map.put(:secret_key_base, @secret_key_base)
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)

      for {key, _value} <- Application.get_all_env(:gsmlg_browser) do
        Application.delete_env(:gsmlg_browser, key)
      end

      for {key, value} <- browser_config do
        Application.put_env(:gsmlg_browser, key, value)
      end
    end)

    %{conn: conn, user: user}
  end

  test "all required Browser pages render stable accessible states", %{conn: conn} do
    for {path, selector} <- [
          {"/browser", "#browser-dashboard"},
          {"/browser/nodes", "#browser-nodes"},
          {"/browser/profiles", "#browser-profiles"},
          {"/browser/sessions", "#browser-sessions"},
          {"/browser/jobs", "#browser-jobs"},
          {"/browser/jobs/new", "#browser-job-new"},
          {"/browser/settings", "#browser-settings"}
        ] do
      assert {:ok, view, _html} = live(conn, path)
      assert has_element?(view, "main#browser-control")
      assert has_element?(view, selector)
      assert has_element?(view, "#browser-navigation[aria-label='Browser Control']")
    end
  end

  test "active Browser navigation uses a theme-safe high-contrast color pair", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/browser/settings")

    assert has_element?(
             view,
             "#browser-navigation a[aria-current='page'].bg-primary-container.text-on-primary-container",
             "Settings"
           )
  end

  test "refresh exposes an explicit loading state before replacing the page data", %{conn: conn} do
    assert {:ok, view, _html} = live(conn, "/browser")

    html = view |> element("#browser-refresh") |> render_click()

    assert html =~ ~s(id="browser-loading")
    assert html =~ ~s(role="status")
    refute render(view) =~ ~s(id="browser-loading")
  end

  test "new-job form builds the complete versioned workflow contracts", %{
    conn: conn,
    user: user
  } do
    %{node: node, profile: profile} = insert_inventory()
    %{node: youtube_node, profile: youtube_profile} = insert_inventory()
    register_browser_agent(node)
    register_browser_agent(youtube_node)

    deep_key = "ui-deep-#{System.unique_integer([:positive])}"
    assert {:ok, deep_view, _html} = live(conn, "/browser/jobs/new")
    put_live_testing_mode(deep_view, :manual)

    assert has_element?(deep_view, "#browser-required-output-report-markdown", "Markdown report")
    assert has_element?(deep_view, "#browser-required-output-report-json", "Structured JSON")
    assert has_element?(deep_view, "#browser-required-output-sources-json", "Sources JSON")
    assert has_element?(deep_view, "#browser-job-report-html")
    assert has_element?(deep_view, "#browser-job-screenshot-png")

    _deep_submit =
      deep_view
      |> form("#browser-job-form",
        job: %{
          workflow: "gemini.deep_research",
          workflow_version: "1",
          prompt: "Research a bounded topic",
          output_locale: "en",
          research_scope: "public web sources",
          required_sections: "Summary\nEvidence",
          node_id: node.id,
          profile_id: profile.id,
          idempotency_key: deep_key,
          report_html: "true",
          screenshot_png: "true",
          auto_approve_plan: "true"
        }
      )
      |> render_submit()

    deep_job = Repo.get_by!(Job, requested_by_actor_id: user.id, idempotency_key: deep_key)
    assert_redirect(deep_view, "/browser/jobs/#{deep_job.id}")

    assert deep_job.input == %{
             "auto_approve_plan" => true,
             "output_locale" => "en",
             "prompt" => "Research a bounded topic",
             "required_sections" => ["Summary", "Evidence"],
             "research_scope" => "public web sources"
           }

    assert deep_job.output_formats == [
             "report.markdown",
             "report.json",
             "sources.json",
             "report.html",
             "screenshot.png"
           ]

    youtube_key = "ui-youtube-#{System.unique_integer([:positive])}"
    assert {:ok, youtube_view, _html} = live(conn, "/browser/jobs/new")
    put_live_testing_mode(youtube_view, :manual)

    _youtube_submit =
      youtube_view
      |> form("#browser-job-form",
        job: %{
          workflow: "gemini.youtube_analysis",
          workflow_version: "1",
          youtube_url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
          analysis_profile: "technical_review",
          output_locale: "en",
          custom_instructions: "Include timestamps.",
          use_deep_research: "true",
          node_id: youtube_node.id,
          profile_id: youtube_profile.id,
          idempotency_key: youtube_key,
          report_html: "true"
        }
      )
      |> render_submit()

    youtube_job = Repo.get_by!(Job, requested_by_actor_id: user.id, idempotency_key: youtube_key)
    assert_redirect(youtube_view, "/browser/jobs/#{youtube_job.id}")

    assert youtube_job.input == %{
             "analysis_profile" => "technical_review",
             "custom_instructions" => "Include timestamps.",
             "output_locale" => "en",
             "use_deep_research" => true,
             "youtube_url" => "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
           }

    assert youtube_job.output_formats == [
             "report.markdown",
             "report.json",
             "sources.json",
             "report.html"
           ]
  end

  test "forged LiveView events reject malformed workflow versions and missing job context", %{
    conn: conn,
    user: user
  } do
    %{node: node, profile: profile} = insert_inventory()
    register_browser_agent(node)

    assert {:ok, new_view, _html} = live(conn, "/browser/jobs/new")

    html =
      render_hook(new_view, "create_job", %{
        "job" => %{
          "workflow" => "gemini.deep_research",
          "workflow_version" => "not-a-version",
          "prompt" => "Research a bounded topic",
          "output_locale" => "en",
          "research_scope" => "public web sources",
          "required_sections" => "Summary",
          "node_id" => node.id,
          "profile_id" => profile.id,
          "idempotency_key" => "malformed-version-#{System.unique_integer([:positive])}",
          "auto_approve_plan" => "true"
        }
      })

    assert html =~ "The browser request is invalid."
    refute Repo.get_by(Job, requested_by_actor_id: user.id)

    assert {:ok, dashboard, _html} = live(conn, "/browser")

    assert render_hook(dashboard, "job_action", %{"action" => "cancel"}) =~
             "Unsupported job action"
  end

  test "dashboard and inventory render sanitized fleet state", %{conn: conn, user: user} do
    %{node: node, profile: profile} = insert_inventory()

    register_browser_agent(node)

    session =
      %Session{}
      |> Session.changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        mode: "automation",
        status: "ready",
        owner_actor_id: user.id,
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })
      |> Repo.insert!()

    {:ok, dashboard, _html} = live(conn, "/browser")
    assert has_element?(dashboard, "#browser-online-nodes", "1")
    assert has_element?(dashboard, "#browser-available-profiles", "1")
    assert has_element?(dashboard, "#browser-active-sessions", "1")
    assert has_element?(dashboard, "#browser-node-states", "online 1")
    assert has_element?(dashboard, "#browser-profile-states", "available 1")
    assert has_element?(dashboard, "#browser-manager-states", "available 1")
    assert has_element?(dashboard, "#browser-tls-states", "verified 1")
    assert has_element?(dashboard, "#browser-artifact-states", "none")

    {:ok, sessions, _html} = live(conn, "/browser/sessions")
    assert has_element?(sessions, "#browser-session-#{session.id}", "ready")

    {:ok, nodes, _html} = live(conn, "/commander/#{node.commander_id}/browser")
    assert has_element?(nodes, "#browser-node-#{node.id}", node.commander_id)
    assert has_element?(nodes, "#browser-node-#{node.id}", "1.2.3")
    assert has_element?(nodes, "#browser-node-#{node.id}", "130.0.1")
    refute render(nodes) =~ "secret"
  end

  test "an already-open node inventory discovers Commander Browser Agent connections", %{
    conn: conn
  } do
    commander_id = "connected-browser-#{System.unique_integer([:positive])}"
    connection_id = {:browser_live_test, commander_id}

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(30, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    assert {:ok, view, _html} = live(conn, "/browser/nodes")
    refute render(view) =~ commander_id

    info = %{
      protocol_version: 1,
      tls: %{
        "status" => "verified",
        "certificate_expires_at" => expires_at
      },
      capability_descriptors: [
        %{
          "id" => "browser.control",
          "version" => 1,
          "backend" => "cloakbrowser",
          "operations" => ["profiles.list"],
          "limits" => %{
            "max_profiles_running" => 1,
            "max_sessions" => 2,
            "max_workflows" => 1
          },
          "workflows" => ["gemini.deep_research/v1"]
        }
      ]
    }

    {:ok, generation} =
      AgentRegistry.activate_agent(commander_id, self(), info, connection_id)

    on_exit(fn -> AgentRegistry.unregister_agent(commander_id, self(), generation) end)

    assert has_element?(view, "#browser-nodes", commander_id)
    assert has_element?(view, "#browser-nodes", "browser.control/v1")
    assert has_element?(view, "#browser-nodes", "cloakbrowser")

    assert %Node{id: node_id, commander_id: ^commander_id} =
             Repo.get_by(Node, commander_id: commander_id)

    assert has_element?(view, "#browser-node-#{node_id}-tls", "verified")
    assert has_element?(view, "#browser-node-#{node_id}-tls", expires_at)
    assert has_element?(view, "#browser-node-#{node_id}-tls", "remaining")
    assert render(view) =~ "max_sessions"

    :ok = AgentRegistry.unregister_agent(commander_id, self(), generation)
    assert has_element?(view, "#browser-nodes", "offline")
  end

  test "profile inventory configures enabled, default, and canonical origin policy", %{conn: conn} do
    %{node: node, profile: original_default} = insert_inventory()

    configured =
      %Profile{}
      |> Profile.changeset(%{
        node_id: node.id,
        external_id: "profile-configured-#{System.unique_integer([:positive])}",
        name: "Configurable profile",
        backend: node.default_backend,
        is_default: false,
        runtime_status: "running",
        automation_status: "available"
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, "/browser/profiles")

    view
    |> form("#browser-profile-policy-#{configured.id}",
      profile: %{
        id: configured.id,
        enabled: "true",
        is_default: "true",
        allowed_origins: "https://gemini.google.com\nhttps://www.youtube.com"
      }
    )
    |> render_submit()

    assert %Profile{
             enabled: true,
             is_default: true,
             policy: %{
               "allowed_origins" => [
                 "https://gemini.google.com",
                 "https://www.youtube.com"
               ]
             }
           } = Repo.get!(Profile, configured.id)

    refute Repo.get!(Profile, original_default.id).is_default
    assert has_element?(view, "#browser-profile-#{configured.id}", "default")
    assert has_element?(view, "#browser-profile-policy-#{configured.id}", "Save policy")
  end

  test "job detail displays phase, intervention, events, and verified artifacts", %{
    conn: conn,
    user: user
  } do
    %{node: node, profile: profile} = insert_inventory()
    remote_execution_id = Ecto.UUID.generate()

    session =
      %Session{}
      |> Session.changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        remote_session_id: Ecto.UUID.generate(),
        mode: "automation",
        status: "waiting_human",
        owner_actor_id: user.id,
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })
      |> Repo.insert!()

    job =
      %Job{}
      |> Job.create_changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        session_id: session.id,
        remote_execution_id: remote_execution_id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "waiting_human",
        phase: "login_required",
        chat_url: "https://gemini.google.com/app/authorized-chat",
        input: %{"prompt" => "sensitive prompt"},
        output_formats: ["report.markdown", "report.json", "sources.json"],
        idempotency_key: Ecto.UUID.generate(),
        requested_by_actor_id: user.id,
        deadline_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    event =
      %JobEvent{}
      |> JobEvent.changeset(%{
        job_id: job.id,
        remote_execution_id: remote_execution_id,
        sequence: 1,
        event: "intervention.required",
        phase: "login_required",
        metadata: %{"reason" => "login_required"},
        occurred_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    content = "# Verified report\n"
    artifact_id = Ecto.UUID.generate()

    %Artifact{}
    |> Artifact.manifest_changeset(%{
      id: artifact_id,
      job_id: job.id,
      kind: "report.markdown",
      mime: "text/markdown",
      filename: "report.md",
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

    {:ok, view, html} = live(conn, "/browser/jobs/#{job.id}")

    assert has_element?(view, "#browser-job-detail-#{job.id}", "login_required")
    assert has_element?(view, "#browser-job-intervention")
    assert has_element?(view, "#browser-job-intervention-reason", "login_required")
    assert has_element?(view, "#browser-job-intervention-profile", profile.id)
    assert has_element?(view, "#browser-job-manual-lease-state", "Automation paused")
    assert has_element?(view, "#browser-job-intervention-instructions", "Sign in")
    assert has_element?(view, "#browser-job-ssh-tunnel", "ssh -N -L")
    assert has_element?(view, "#browser-job-event-#{event.sequence}", "intervention.required")
    assert has_element?(view, "#browser-artifact-#{artifact_id}", "report.md")
    assert has_element?(view, "#browser-job-cancel")
    assert has_element?(view, "#browser-job-retry[disabled]")
    assert has_element?(view, "#browser-job-resume")
    assert has_element?(view, "#browser-job-reconcile")
    assert has_element?(view, "#browser-job-result-summary")
    assert has_element?(view, "#browser-job-result-status", "waiting_human")
    assert has_element?(view, "#browser-job-manual-acquire", "Acquire manual lease")
    assert has_element?(view, "#browser-job-manual-release", "Release manual lease")

    assert has_element?(
             view,
             "#browser-job-chat-url[href='https://gemini.google.com/app/authorized-chat']"
           )

    refute html =~ "sensitive prompt"

    download = get(conn, "/browser/artifacts/#{artifact_id}/content")
    assert response(download, 200) == content
    assert get_resp_header(download, "cache-control") == ["private, no-store"]
    assert get_resp_header(download, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(download, "x-artifact-sha256") == [
             :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
           ]

    partial =
      conn
      |> put_req_header("range", "bytes=0-3")
      |> get("/browser/artifacts/#{artifact_id}/content")

    assert response(partial, 206) == "# Ve"
    assert get_resp_header(partial, "content-range") == ["bytes 0-3/#{byte_size(content)}"]

    %JobEvent{}
    |> JobEvent.changeset(%{
      job_id: job.id,
      remote_execution_id: remote_execution_id,
      sequence: 2,
      event: "intervention.cleared",
      phase: "resuming",
      metadata: %{},
      occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    job
    |> Job.transition_changeset(%{status: "running", phase: "resuming"})
    |> Repo.update!()

    view |> element("#browser-refresh") |> render_click()
    refute has_element?(view, "#browser-job-intervention")
  end

  test "queued jobs can be cancelled", %{conn: conn, user: user} do
    %{node: node, profile: profile} = insert_inventory()

    job =
      %Job{}
      |> Job.create_changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "queued",
        input: %{},
        output_formats: ["report.markdown", "report.json", "sources.json"],
        idempotency_key: Ecto.UUID.generate(),
        requested_by_actor_id: user.id,
        deadline_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      })
      |> Repo.insert!()

    assert {:ok, view, _html} = live(conn, "/browser/jobs/#{job.id}")
    assert has_element?(view, "#browser-job-cancel")
    refute has_element?(view, "#browser-job-cancel[disabled]")
  end

  test "session artifact download aborts after a later bounded storage read fails", %{
    conn: conn,
    user: user
  } do
    %{node: node, profile: profile} = insert_inventory()
    object = :binary.copy("a", 65_536 + 10)
    start_artifact_storage_stub!(object, ["bytes=65536-65545"])

    job =
      %Job{}
      |> Job.create_changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "completed",
        input: %{},
        output_formats: ["report.markdown", "report.json", "sources.json"],
        idempotency_key: Ecto.UUID.generate(),
        requested_by_actor_id: user.id,
        deadline_at: DateTime.add(DateTime.utc_now(), 3_600, :second),
        completed_at: DateTime.utc_now()
      })
      |> Repo.insert!()

    storage_file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: "browser",
        type: "artifact",
        filename: "large-report.md",
        s3_key: "browser/e2e/#{Ecto.UUID.generate()}",
        content_type: "text/markdown",
        size: byte_size(object),
        checksum: :crypto.hash(:sha256, object) |> Base.encode16(case: :lower)
      })
      |> Repo.insert!()

    artifact =
      %Artifact{}
      |> Artifact.manifest_changeset(%{
        id: Ecto.UUID.generate(),
        job_id: job.id,
        kind: "report.markdown",
        mime: "text/markdown",
        filename: "large-report.md",
        size: byte_size(object),
        sha256: storage_file.checksum,
        transfer_mode: "signed_upload",
        status: "verified",
        storage_type: "storage",
        storage_ref: storage_file.id,
        verified_at: DateTime.utc_now(),
        ack_status: "acked"
      })
      |> Repo.insert!()

    assert {:shutdown, :browser_artifact_read_failed} =
             catch_exit(get(conn, "/browser/artifacts/#{artifact.id}/content"))

    assert_receive {:artifact_s3_get, ["bytes=0-65535"]}
    assert_receive {:artifact_s3_get, ["bytes=65536-65545"]}
  end

  test "disabled Browser service renders a fail-closed state", %{conn: conn} do
    Application.put_env(:gsmlg_browser, :enabled, false)
    assert {:ok, view, _html} = live(conn, "/browser")
    assert has_element?(view, "#browser-service-state", "unavailable")
    assert has_element?(view, "#browser-dashboard")
  end

  defp insert_inventory do
    tls_expires_at =
      DateTime.utc_now()
      |> DateTime.add(30, :day)
      |> DateTime.truncate(:second)
      |> DateTime.to_iso8601()

    node =
      %Node{}
      |> Node.changeset(%{
        commander_id: "browser-host-#{System.unique_integer([:positive])}",
        default_backend: "cloak",
        status: "online",
        limits: %{"max_sessions" => 2},
        metadata: %{
          "manager_status" => "available",
          "agent_version" => "1.2.3",
          "browser_version" => "130.0.1",
          "tls_status" => "verified",
          "tls_expires_at" => tls_expires_at,
          "tls_remaining_seconds" => 30 * 86_400
        }
      })
      |> Repo.insert!()

    profile =
      %Profile{}
      |> Profile.changeset(%{
        node_id: node.id,
        external_id: "profile-#{System.unique_integer([:positive])}",
        name: "Research profile",
        backend: "cloak",
        is_default: true,
        runtime_status: "running",
        automation_status: "available",
        locale: "en-US"
      })
      |> Repo.insert!()

    %{node: node, profile: profile}
  end

  defp start_artifact_storage_stub!(object, fail_ranges) do
    keys = [
      :browser_live_artifact_pid,
      :browser_live_artifact_object,
      :browser_live_artifact_fail_ranges,
      :s3_access_key_id,
      :s3_bucket,
      :s3_endpoint,
      :s3_secret_access_key
    ]

    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, stub} = Bandit.start_link(plug: ArtifactS3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :browser_live_artifact_pid, self())
    Application.put_env(:gsmlg_storage, :browser_live_artifact_object, object)
    Application.put_env(:gsmlg_storage, :browser_live_artifact_fail_ranges, fail_ranges)
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      if Process.alive?(stub) do
        try do
          GenServer.stop(stub)
        catch
          :exit, _reason -> :ok
        end
      end
    end)
  end

  defp available_port do
    {:ok, socket} = :gen_tcp.listen(0, active: false)
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp register_browser_agent(node) do
    connection_id = {:browser_live_fixture, node.commander_id}

    {:ok, generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        self(),
        %{
          protocol_version: 1,
          tls: %{
            "status" => "verified",
            "certificate_expires_at" => node.metadata["tls_expires_at"]
          },
          capability_descriptors: [
            %{
              "id" => "browser.control",
              "version" => 1,
              "backend" => node.default_backend,
              "operations" => ["profiles.list"],
              "limits" => node.limits,
              "workflows" => ["gemini.deep_research/v1", "gemini.youtube_analysis/v1"]
            }
          ]
        },
        connection_id
      )

    on_exit(fn -> AgentRegistry.unregister_agent(node.commander_id, self(), generation) end)
  end

  defp put_live_testing_mode(view, mode) do
    :sys.replace_state(view.pid, fn state ->
      Process.put(:oban_testing, mode)
      state
    end)
  end
end
