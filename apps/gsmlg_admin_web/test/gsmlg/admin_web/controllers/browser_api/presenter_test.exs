defmodule GSMLG.AdminWeb.BrowserAPI.PresenterTest do
  use ExUnit.Case, async: true

  alias GSMLG.AdminWeb.BrowserAPI.Presenter
  alias GSMLG.Browser.{Artifact, Job, JobEvent, Node, Profile, Session}

  test "database resources expose only their public allowlists" do
    node = %Node{
      id: Ecto.UUID.generate(),
      commander_id: "node-1",
      enabled: true,
      default_backend: "cloak_browser",
      status: "online",
      online?: true,
      capabilities: [
        %{
          "id" => "browser.control",
          "version" => 1,
          "backend" => "cloak_browser",
          "operations" => ["session.open", %{"token" => "must-not-leak"}],
          "limits" => %{"max_sessions" => 2, "private" => %{"token" => "must-not-leak"}},
          "workflows" => ["gemini.deep_research/v1"],
          "token" => "must-not-leak"
        }
      ],
      limits: %{"sessions" => 2, "private" => %{"token" => "must-not-leak"}},
      metadata: %{
        "manager_status" => "available",
        "agent_version" => "1.2.3",
        "browser_version" => "130.0.1",
        "token" => "must-not-leak"
      },
      last_error: %{"message" => "secret", "code" => "manager_down"}
    }

    assert %{
             commander_id: "node-1",
             status: "online",
             online: true,
             manager_status: "available",
             agent_version: "1.2.3",
             browser_version: "130.0.1",
             error_code: "manager_down"
           } = public_node = Presenter.node(node)

    assert public_node.id == node.id

    refute Map.has_key?(public_node, :metadata)
    refute inspect(public_node) =~ "must-not-leak"
    refute inspect(public_node) =~ "secret"
    assert public_node.limits == %{"sessions" => 2}
    assert [capability] = public_node.capabilities
    assert capability["operations"] == ["session.open"]
    assert capability["limits"] == %{"max_sessions" => 2}
    refute Map.has_key?(capability, "token")

    profile = %Profile{
      id: Ecto.UUID.generate(),
      node_id: node.id,
      external_id: "profile-remote",
      name: "Research",
      backend: "cloak_browser",
      enabled: true,
      runtime_status: "running",
      automation_status: "available",
      locale: "en-US",
      timezone: "Asia/Shanghai",
      screen: %{
        "width" => 1_920,
        "height" => 1_080,
        "device_scale_factor" => 2.0,
        "token" => "must-not-leak"
      },
      policy: %{
        "allowed_origins" => ["https://gemini.google.com", "https://www.youtube.com"],
        "token" => "must-not-leak"
      },
      last_error: %{"code" => "profile_error", "details" => "secret"}
    }

    assert %{error_code: "profile_error"} = public_profile = Presenter.profile(profile)
    assert public_profile.id == profile.id

    assert public_profile.allowed_origins == [
             "https://gemini.google.com",
             "https://www.youtube.com"
           ]

    refute Map.has_key?(public_profile, :policy)

    assert public_profile.screen == %{
             "width" => 1_920,
             "height" => 1_080,
             "device_scale_factor" => 2.0
           }

    refute inspect(public_profile) =~ "must-not-leak"

    session = %Session{
      id: Ecto.UUID.generate(),
      node_id: node.id,
      profile_id: profile.id,
      remote_session_id: Ecto.UUID.generate(),
      lease_id: Ecto.UUID.generate(),
      mode: "automation",
      status: "ready",
      revision: 3,
      owner_actor_id: "actor-secret",
      origin_policy: %{"origins" => ["https://secret.example"]}
    }

    public_session = Presenter.session(session)
    assert %{revision: 3} = public_session
    assert public_session.id == session.id
    refute Map.has_key?(public_session, :remote_session_id)
    refute Map.has_key?(public_session, :lease_id)
    refute Map.has_key?(public_session, :owner_actor_id)
    refute Map.has_key?(public_session, :origin_policy)
  end

  test "jobs, events, and artifacts omit remote identities and stored content" do
    job = %Job{
      id: Ecto.UUID.generate(),
      node_id: Ecto.UUID.generate(),
      profile_id: Ecto.UUID.generate(),
      remote_execution_id: Ecto.UUID.generate(),
      workflow: "gemini.deep_research",
      workflow_version: 1,
      status: "completed",
      input: %{"prompt" => "private prompt"},
      idempotency_key: "private-key",
      control_keys: %{"cancel" => "private-control"},
      requested_by_actor_id: "private-actor",
      result: %{
        "last_sequence" => 7,
        "artifact_count" => 4,
        "pending_artifact_count" => 0,
        "remote_completed" => true,
        "markdown" => "report body",
        "nested" => %{"prompt" => "private prompt"}
      },
      error: %{"code" => "stable_failure", "details" => "private-details"}
    }

    public_job = Presenter.job(job)
    assert %{workflow: "gemini.deep_research", error_code: "stable_failure"} = public_job
    assert public_job.id == job.id
    assert public_job.result_available

    assert public_job.result == %{
             "last_sequence" => 7,
             "artifact_count" => 4,
             "pending_artifact_count" => 0,
             "remote_completed" => true
           }

    for forbidden <- [
          :remote_execution_id,
          :input,
          :idempotency_key,
          :control_keys,
          :requested_by_actor_id
        ] do
      refute Map.has_key?(public_job, forbidden)
    end

    refute inspect(public_job) =~ "report body"
    refute inspect(public_job) =~ "private prompt"

    event = %JobEvent{
      id: Ecto.UUID.generate(),
      job_id: job.id,
      remote_execution_id: Ecto.UUID.generate(),
      sequence: 4,
      event: "intervention.required",
      phase: "authenticate",
      metadata: %{
        "central_job_id" => job.id,
        "intervention_reason" => "login_required",
        "token" => "must-not-leak"
      }
    }

    public_event = Presenter.event(event)
    assert public_event.metadata == %{"intervention_reason" => "login_required"}
    refute Map.has_key?(public_event, :remote_execution_id)

    artifact = %Artifact{
      id: Ecto.UUID.generate(),
      job_id: job.id,
      kind: "report.markdown",
      mime: "text/markdown",
      filename: "report.md",
      size: 11,
      sha256: String.duplicate("a", 64),
      transfer_mode: "inline",
      status: "verified",
      inline_content: "report body",
      storage_ref: Ecto.UUID.generate(),
      upload_token_digest: "private-token-digest"
    }

    public_artifact = Presenter.artifact(artifact)
    assert %{status: "verified"} = public_artifact
    assert public_artifact.id == artifact.id
    assert public_artifact.job_id == job.id
    refute Map.has_key?(public_artifact, :session_id)

    for forbidden <- [:inline_content, :storage_ref, :upload_token_digest, :upload_expires_at] do
      refute Map.has_key?(public_artifact, forbidden)
    end
  end

  test "job result manifests are bounded and closed" do
    public =
      Presenter.job(%Job{
        result: %{
          "last_sequence" => 1_000_000_001,
          "artifact_count" => -1,
          "pending_artifact_count" => "3",
          "remote_completed" => "true",
          "report" => "private content"
        }
      })

    assert public.result == %{
             "last_sequence" => 1_000_000_000,
             "artifact_count" => 0,
             "pending_artifact_count" => 0,
             "remote_completed" => false
           }

    refute inspect(public) =~ "private content"
    assert %{result: nil, result_available: false} = Presenter.job(%Job{result: nil})
  end

  test "remote observations and action results are recursively allowlisted and bounded" do
    observation = %{
      "revision" => 1,
      "url" => "https://example.test",
      "origin" => "https://example.test",
      "title" => "Example",
      "page_kind" => "document",
      "loading_state" => "complete",
      "visible_controls" => [
        %{
          "node_id" => "control-1",
          "role" => "textbox",
          "name" => "Password",
          "value" => "super-secret",
          "state" => %{"focused" => true, "cookie" => "must-not-leak"},
          "attributes" => %{
            "type" => "password",
            "aria-label" => "Password",
            "cookie" => "must-not-leak"
          },
          "cookie" => "must-not-leak"
        }
      ],
      "semantic_tree" => [
        %{
          "node_id" => "node-1",
          "role" => "link",
          "name" => "Docs",
          "attributes" => %{
            "href" => "https://example.test/docs",
            "local_storage" => "must-not-leak"
          }
        }
      ],
      "alerts" => ["Notice", %{"token" => "must-not-leak"}],
      "focused_element" => %{
        "node_id" => "control-1",
        "role" => "textbox",
        "name" => "Password",
        "value" => "must-not-leak"
      },
      "observed_at" => "2026-09-06T09:00:00Z",
      "cookie" => "must-not-leak",
      "lease_id" => Ecto.UUID.generate()
    }

    public_observation = Presenter.observation(observation)
    refute Map.has_key?(public_observation, "cookie")
    refute Map.has_key?(public_observation, "lease_id")
    assert public_observation["origin"] == "https://example.test"
    assert public_observation["loading_state"] == "complete"
    assert public_observation["alerts"] == ["Notice"]
    assert get_in(public_observation, ["visible_controls", Access.at(0), "value"]) == "[REDACTED]"
    refute inspect(public_observation) =~ "super-secret"
    refute inspect(public_observation) =~ "must-not-leak"

    result = %{
      "action_id" => "action-1",
      "revision" => 2,
      "observation" => observation,
      "output" => %{
        "status" => "clicked",
        "values" => ["one", %{"token" => "must-not-leak"}],
        "raw" => %{"token" => "must-not-leak"}
      },
      "raw_cdp" => "must-not-leak"
    }

    public = Presenter.action_result(result)
    assert public["action_id"] == "action-1"
    assert public["output"]["values"] == ["one"]
    refute Map.has_key?(public, "raw_cdp")
    refute Map.has_key?(public["observation"], "cookie")
    refute inspect(public) =~ "must-not-leak"

    artifact_result = %{
      "action_id" => "screenshot-1",
      "revision" => 3,
      "output" => %{
        "artifact" => %{
          "artifact_id" => Ecto.UUID.generate(),
          "kind" => "screenshot.png",
          "mime" => "image/png",
          "filename" => "screenshot.png",
          "size" => 3,
          "sha256" => String.duplicate("a", 64),
          "status" => "pending",
          "session_id" => Ecto.UUID.generate(),
          "remote_session_id" => Ecto.UUID.generate(),
          "transfer_mode" => "remote_pending",
          "metadata" => %{"source_url" => "https://example.test/?token=secret"}
        }
      }
    }

    public_artifact = Presenter.action_result(artifact_result)["output"]["artifact"]
    assert public_artifact["kind"] == "screenshot.png"
    assert public_artifact["status"] == "pending"
    refute Map.has_key?(public_artifact, "session_id")
    refute Map.has_key?(public_artifact, "remote_session_id")
    refute Map.has_key?(public_artifact, "transfer_mode")
    refute Map.has_key?(public_artifact, "metadata")
    refute inspect(public_artifact) =~ "secret"
  end
end
