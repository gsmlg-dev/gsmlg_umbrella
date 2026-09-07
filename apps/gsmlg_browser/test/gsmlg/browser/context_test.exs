defmodule GSMLG.Browser.ContextTest do
  use GSMLG.Browser.DataCase, async: false

  alias GSMLG.Browser
  alias GSMLG.Browser.{Artifact, Error, Job, Node, Profile, Session}
  alias GSMLG.CommandPlatform.{AgentRegistry, RPCDispatcher}
  alias GSMLG.Commander.Protocol.{Envelope, RPCAccepted, RPCError, RPCResponse}

  defmodule OnlineRegistry do
    def list_agents do
      [
        %{
          agent_id: "live-browser",
          last_heartbeat: 1_000,
          info: %{
            capability_descriptors: [
              %{
                "id" => "browser.control",
                "version" => 1,
                "backend" => "cloakbrowser",
                "operations" => ["profiles.list"],
                "limits" => %{"max_workflows" => 1},
                "workflows" => ["gemini.deep_research/v1"]
              }
            ]
          }
        }
      ]
    end
  end

  defmodule DescriptorAuthoritativeRegistry do
    def list_agents do
      [
        %{
          agent_id: "legacy-only",
          info: %{
            capability_descriptors: [],
            capabilities: [%{"id" => "browser.control", "version" => 1}]
          }
        }
      ]
    end
  end

  defmodule DiscoveredRegistry do
    def list_agents do
      [
        %{
          agent_id: "discovered-browser",
          connected_at: 1_788_694_200_000,
          last_heartbeat: 1_788_694_201_000,
          info: %{
            capability_descriptors: [
              %{
                "id" => "browser.control",
                "version" => 1,
                "backend" => "cloakbrowser",
                "operations" => ["manager.status", "profiles.list"],
                "limits" => %{
                  "max_profiles_running" => 1,
                  "max_sessions" => 2,
                  "max_workflows" => 1
                },
                "workflows" => ["gemini.deep_research/v1"]
              }
            ]
          }
        }
      ]
    end
  end

  defmodule EmptyRegistry do
    def list_agents, do: []
  end

  defmodule MixedRegistry do
    def list_agents do
      GSMLG.Browser.ContextTest.DiscoveredRegistry.list_agents() ++
        [
          %{
            agent_id: "malformed-browser",
            info: %{
              capability_descriptors: [
                %{
                  "id" => "browser.control",
                  "version" => 1,
                  "backend" => "cloakbrowser",
                  "operations" => ["manager.status", %{"token" => "must-not-leak"}],
                  "limits" => %{"max_sessions" => 2},
                  "workflows" => []
                }
              ]
            }
          }
        ]
    end
  end

  defmodule TLSRegistry do
    def list_agents do
      expires_at =
        DateTime.utc_now()
        |> DateTime.add(30, :day)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      [
        %{
          agent_id: "live-tls-browser",
          last_heartbeat: System.system_time(:millisecond),
          info: %{
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
                "limits" => %{"max_workflows" => 1},
                "workflows" => []
              }
            ]
          }
        }
      ]
    end
  end

  test "create_job is actor explicit, idempotent, and transactionally enqueues dispatch" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    attrs = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      input: deep_input("Research BEAM"),
      output_formats: output_formats(),
      idempotency_key: "same-create"
    }

    assert {:error, %Error{code: "actor_required"}} = Browser.create_job(nil, attrs)
    assert {:ok, %Job{} = first} = Browser.create_job(actor, attrs)
    assert {:ok, %Job{id: same_id}} = Browser.create_job(actor, attrs)
    assert same_id == first.id

    assert [%Oban.Job{args: %{"job_id" => job_id}, worker: worker}] =
             Repo.all(from(job in Oban.Job, where: job.args["job_id"] == ^first.id))

    assert job_id == first.id
    assert worker == "GSMLG.Browser.Workers.DispatchWorker"
    assert Repo.get!(Profile, profile.id).automation_status == "leased"
  end

  test "profile admission is serialized and rejects a second distinct workflow" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    base = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      input: deep_input("first"),
      output_formats: output_formats()
    }

    assert {:ok, %Job{}} = Browser.create_job(actor, Map.put(base, :idempotency_key, "first"))

    assert {:error, %Error{code: "profile_busy"}} =
             Browser.create_job(actor, Map.put(base, :idempotency_key, "second"))
  end

  test "node queries merge persistent policy with live Commander browser capability" do
    actor = actor_fixture()

    _offline = node_fixture(%{commander_id: "configured-only"})

    live =
      node_fixture(%{
        commander_id: "live-browser",
        status: "online",
        capabilities: [%{"id" => "old"}],
        limits: %{}
      })

    assert {:ok, nodes} = Browser.list_nodes(actor, agent_registry: OnlineRegistry)

    assert %{online?: true, status: "online", limits: %{"max_workflows" => 1}} =
             Enum.find(nodes, &(&1.id == live.id))

    assert %{online?: false, status: "offline"} =
             Enum.find(nodes, &(&1.commander_id == "configured-only"))
  end

  test "node inventory derives bounded TLS expiry and remaining validity from the live registry" do
    actor = actor_fixture()

    assert {:ok,
            [
              %Node{
                commander_id: "live-tls-browser",
                online?: true,
                metadata: %{
                  "tls_status" => "verified",
                  "tls_expires_at" => expires_at,
                  "tls_remaining_seconds" => remaining_seconds
                }
              } = node
            ]} = Browser.list_nodes(actor, agent_registry: TLSRegistry)

    assert {:ok, _expires_at, 0} = DateTime.from_iso8601(expires_at)
    assert remaining_seconds in (29 * 86_400)..(30 * 86_400)

    assert Map.keys(node.metadata) |> Enum.sort() == [
             "tls_expires_at",
             "tls_remaining_seconds",
             "tls_status"
           ]

    refute inspect(node.metadata) =~ "certificate"

    assert %Node{metadata: persisted_metadata} =
             Repo.get_by(Node, commander_id: "live-tls-browser")

    assert persisted_metadata["tls_status"] == "verified"
    assert persisted_metadata["tls_expires_at"] == expires_at
  end

  test "a newly connected Browser Agent is discovered and stores only bounded health metadata" do
    actor = actor_fixture()
    secret = "manager-token-must-not-persist"
    test_process = self()

    dispatch = fn request ->
      send(test_process, {:manager_status, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "status" => "available",
           "backend" => "cloakbrowser",
           "agent_version" => "1.2.3",
           "binary_version" => "130.0.1",
           "profiles_total" => 4,
           "running_count" => 1,
           "runtime_mode" => "docker",
           "token" => secret
         }
       }}
    end

    refute Repo.get_by(Node, commander_id: "discovered-browser")

    assert {:ok,
            [
              %Node{
                commander_id: "discovered-browser",
                online?: true,
                status: "online",
                default_backend: "cloakbrowser",
                limits: %{
                  "max_profiles_running" => 1,
                  "max_sessions" => 2,
                  "max_workflows" => 1
                },
                metadata: %{
                  "agent_version" => "1.2.3",
                  "browser_version" => "130.0.1",
                  "manager_status" => "available",
                  "profiles_total" => 4,
                  "running_count" => 1,
                  "runtime_mode" => "docker"
                }
              } = node
            ]} =
             Browser.list_nodes(actor,
               agent_registry: MixedRegistry,
               dispatch: dispatch
             )

    assert_received {:manager_status, request}
    assert request.capability == "browser.control"
    assert request.capability_version == 1
    assert request.operation == "manager.status"
    assert request.payload == %{}

    assert %Node{id: persisted_id} = Repo.get_by(Node, commander_id: "discovered-browser")
    assert persisted_id == node.id
    refute Repo.get_by(Node, commander_id: "malformed-browser")
    refute inspect(node) =~ secret
  end

  test "Manager failure degrades a live node and registry disconnect makes it offline" do
    actor = actor_fixture()
    secret = "manager-connection-details-must-not-persist"

    dispatch = fn request ->
      {:error,
       %RPCError{
         protocol_version: 1,
         request_id: request.request_id,
         class: "manager",
         code: "manager_unavailable",
         message: secret,
         retryable: true,
         human_action: "retry",
         details: %{"secret" => secret}
       }}
    end

    assert {:ok,
            [
              %Node{
                commander_id: "discovered-browser",
                online?: true,
                status: "degraded",
                metadata: %{"manager_status" => "degraded"},
                last_error: %{"code" => "manager_unavailable"}
              } = degraded
            ]} =
             Browser.list_nodes(actor,
               agent_registry: DiscoveredRegistry,
               dispatch: dispatch
             )

    refute inspect(degraded) =~ secret

    assert {:ok, [%Node{commander_id: "discovered-browser", online?: false, status: "offline"}]} =
             Browser.list_nodes(actor, agent_registry: EmptyRegistry)
  end

  test "an existing live node refreshes Manager health and Browser Agent versions" do
    actor = actor_fixture()

    node_fixture(%{
      commander_id: "discovered-browser",
      status: "online",
      metadata: %{"agent_version" => "old", "browser_version" => "old"}
    })

    {:ok, responses} =
      Agent.start_link(fn ->
        [
          %{
            "status" => "available",
            "backend" => "cloakbrowser",
            "agent_version" => "1.0.0",
            "binary_version" => "130.0"
          },
          %{
            "status" => "degraded",
            "backend" => "cloakbrowser",
            "agent_version" => "1.1.0",
            "binary_version" => "131.0",
            "error_code" => "manager_probe_failed"
          }
        ]
      end)

    dispatch = fn request ->
      result = Agent.get_and_update(responses, fn [next | rest] -> {next, rest} end)

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: result
       }}
    end

    assert {:ok, [%Node{status: "online", metadata: first_metadata}]} =
             Browser.list_nodes(actor,
               agent_registry: DiscoveredRegistry,
               dispatch: dispatch
             )

    assert first_metadata["manager_status"] == "available"
    assert first_metadata["agent_version"] == "1.0.0"
    assert first_metadata["browser_version"] == "130.0"

    assert {:ok,
            [
              %Node{
                status: "degraded",
                metadata: %{
                  "manager_status" => "degraded",
                  "agent_version" => "1.1.0",
                  "browser_version" => "131.0"
                },
                last_error: %{"code" => "manager_probe_failed"}
              }
            ]} =
             Browser.list_nodes(actor,
               agent_registry: DiscoveredRegistry,
               dispatch: dispatch
             )
  end

  test "negotiated capability descriptors override legacy capability atoms" do
    actor = actor_fixture()
    node = node_fixture(%{commander_id: "legacy-only", status: "online"})

    assert {:ok, nodes} =
             Browser.list_nodes(actor, agent_registry: DescriptorAuthoritativeRegistry)

    assert %{id: id, online?: false, status: "offline"} = List.first(nodes)
    assert id == node.id
  end

  test "profile configuration is actor explicit and atomically selects one safe default" do
    actor = actor_fixture()
    node = node_fixture()
    original_default = profile_fixture(node)
    configured = profile_fixture(node, %{is_default: false})

    attrs = %{
      enabled: true,
      is_default: true,
      allowed_origins: ["https://gemini.google.com", "https://www.youtube.com"]
    }

    assert {:error, %Error{code: "actor_required"}} =
             Browser.configure_profile(nil, configured.id, attrs)

    assert {:ok,
            %Profile{
              id: configured_id,
              enabled: true,
              is_default: true,
              policy: %{
                "allowed_origins" => [
                  "https://gemini.google.com",
                  "https://www.youtube.com"
                ]
              }
            }} = Browser.configure_profile(actor, configured.id, attrs)

    assert configured_id == configured.id
    refute Repo.get!(Profile, original_default.id).is_default
    assert Repo.get!(Profile, configured.id).is_default
  end

  test "profile configuration rejects unsafe origins and cannot clear the only default" do
    actor = actor_fixture()
    node = node_fixture()
    current_default = profile_fixture(node)
    other = profile_fixture(node, %{is_default: false})

    base = %{enabled: true, is_default: false, allowed_origins: ["https://example.test"]}

    for origins <- [
          [],
          ["http://example.test"],
          ["https://user@example.test"],
          ["https://example.test/path"],
          ["https://example.test?token=secret"],
          ["https://EXAMPLE.test"],
          ["https://example.test:443"],
          ["https://localhost"],
          ["https://127.0.0.1"],
          ["https://example.test", "https://example.test"]
        ] do
      assert {:error, %Error{code: "invalid_request"}} =
               Browser.configure_profile(actor, other.id, %{base | allowed_origins: origins})
    end

    assert {:error, %Error{code: "conflict"}} =
             Browser.configure_profile(actor, current_default.id, base)

    assert Repo.get!(Profile, current_default.id).is_default

    assert {:ok, %Profile{enabled: false, is_default: false, automation_status: "disabled"}} =
             Browser.configure_profile(actor, other.id, %{base | enabled: false})

    assert Repo.get!(Profile, current_default.id).is_default

    Repo.update_all(from(profile in Profile, where: profile.node_id == ^node.id),
      set: [is_default: false]
    )

    assert {:error, %Error{code: "conflict"}} =
             Browser.configure_profile(actor, other.id, base)
  end

  test "dispatch timeout becomes unknown and a repeated activation never resubmits start" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    {:ok, job} =
      Browser.create_job(actor, %{
        node_id: node.id,
        profile_id: profile.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        input: deep_input("timeout"),
        output_formats: output_formats(),
        idempotency_key: "dispatch-timeout"
      })

    dispatch = fn request ->
      send(self(), {:workflow_start, request})
      {:error, :rpc_timeout}
    end

    assert {:ok, %Job{status: "unknown", remote_execution_id: nil}} =
             Browser.dispatch_job(job.id, dispatch: dispatch)

    assert_received {:workflow_start, request}
    assert request.operation == "workflow.start"
    assert request.payload["central_job_id"] == job.id
    assert request.payload["requested_by_actor_id"] == actor.id

    assert {:ok, %Job{status: "unknown"}} = Browser.dispatch_job(job.id, dispatch: dispatch)
    refute_received {:workflow_start, _request}
  end

  test "reconcile can discover the remote ID from central_job_id after an unknown dispatch" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)

    job =
      job_fixture(actor, node, profile, %{
        status: "unknown",
        idempotency_key: "unknown-reconcile"
      })

    Repo.update_all(from(item in Profile, where: item.id == ^profile.id),
      set: [automation_status: "leased"]
    )

    remote_id = Ecto.UUID.generate()
    remote_session_id = Ecto.UUID.generate()
    artifact_id = Ecto.UUID.generate()
    content = "# Reconciled\n"
    hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

    reconcile = fn request ->
      send(self(), {:workflow_reconcile, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => job.id,
           "remote_execution_id" => remote_id,
           "remote_session_id" => remote_session_id,
           "status" => "running",
           "phase" => "researching",
           "chat_url" => "https://gemini.google.com/app/reconciled?hl=en",
           "last_sequence" => 3,
           "result" => %{"prompt" => "must not persist", "page_url" => "https://private.invalid"},
           "artifacts" => [
             %{
               "protocol_version" => 1,
               "artifact_id" => artifact_id,
               "job_id" => job.id,
               "kind" => "report.markdown",
               "mime" => "text/markdown",
               "filename" => "report.md",
               "size" => byte_size(content),
               "sha256" => hash,
               "transfer_mode" => "remote_pending",
               "metadata" => %{"remote_execution_id" => remote_id}
             }
           ],
           "outbox" => %{"pending_artifact_count" => 1}
         }
       }}
    end

    assert {:ok,
            %Job{
              remote_execution_id: ^remote_id,
              status: "running",
              session_id: session_id
            }} =
             Browser.reconcile_job_id(job.id, dispatch: reconcile)

    assert is_binary(session_id)
    assert session_id == remote_id

    assert_received {:workflow_reconcile, request}
    assert request.payload == %{"central_job_id" => job.id}

    reconciled = Repo.get!(Job, job.id)
    refute inspect(reconciled.result) =~ "must not persist"
    refute inspect(reconciled.result) =~ "private.invalid"
    assert reconciled.chat_url == "https://gemini.google.com/app/reconciled?hl=en"

    assert %Session{
             id: ^session_id,
             remote_session_id: ^remote_session_id,
             node_id: node_id,
             profile_id: profile_id,
             owner_actor_id: owner_actor_id,
             mode: "automation",
             status: "ready"
           } = Repo.get!(Session, session_id)

    assert node_id == node.id
    assert profile_id == profile.id
    assert owner_actor_id == actor.id

    assert reconciled.result == %{
             "artifact_count" => 1,
             "last_sequence" => 3,
             "pending_artifact_count" => 1
           }

    assert %Artifact{status: "pending", transfer_mode: "remote_pending"} =
             Repo.get!(Artifact, artifact_id)
  end

  test "reconcile rejects an unapproved chat URL without persisting it" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)

    job =
      job_fixture(actor, node, profile, %{
        status: "unknown",
        idempotency_key: "invalid-chat-url"
      })

    reconcile = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => job.id,
           "remote_execution_id" => Ecto.UUID.generate(),
           "status" => "running",
           "phase" => "researching",
           "chat_url" => "https://gemini.google.com.evil.test/app/stolen",
           "last_sequence" => 0,
           "artifacts" => [],
           "outbox" => %{"pending_artifact_count" => 0}
         }
       }}
    end

    assert {:error, :invalid_chat_url} = Browser.reconcile_job_id(job.id, dispatch: reconcile)
    assert Repo.get!(Job, job.id).chat_url == nil
  end

  test "waiting workflow reconciliation binds a manual session that the same actor can acquire" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node, %{automation_status: "manual"})
    remote_execution_id = Ecto.UUID.generate()
    remote_session_id = Ecto.UUID.generate()

    job =
      job_fixture(actor, node, profile, %{
        status: "waiting_human",
        remote_execution_id: remote_execution_id,
        idempotency_key: "manual-session-reconcile"
      })

    reconcile = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => job.id,
           "remote_execution_id" => remote_execution_id,
           "remote_session_id" => remote_session_id,
           "status" => "waiting_human",
           "phase" => "login_required",
           "last_sequence" => 2,
           "artifacts" => [],
           "outbox" => %{"pending_artifact_count" => 0}
         }
       }}
    end

    assert {:ok, %Job{session_id: ^remote_execution_id}} =
             Browser.reconcile_job_id(job.id, dispatch: reconcile)

    assert %Session{
             id: ^remote_execution_id,
             remote_session_id: ^remote_session_id,
             owner_actor_id: owner_actor_id,
             mode: "manual",
             status: "waiting_human",
             lease_id: nil
           } = Repo.get!(Session, remote_execution_id)

    assert owner_actor_id == actor.id

    parent = self()

    channel =
      spawn_link(fn ->
        workflow_manual_loop(
          node.commander_id,
          parent,
          remote_execution_id,
          profile.external_id,
          actor.id
        )
      end)

    {:ok, generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        channel,
        %{capability_descriptors: [%{"id" => "browser.control", "version" => 1}]},
        {:workflow_manual_test, make_ref()}
      )

    on_exit(fn -> AgentRegistry.unregister_agent(node.commander_id, channel, generation) end)

    assert {:ok, %Session{mode: "manual", lease_id: lease_id}} =
             Browser.manual_acquire(actor, remote_execution_id)

    assert is_binary(lease_id)
    assert_receive {:workflow_manual_acquire, request}
    assert request.payload["session_id"] == remote_session_id
    assert request.payload["operator_id"] == actor.id

    assert {:ok, %Job{status: "running", session_id: ^remote_execution_id}} =
             Browser.resume_job(actor, job.id)

    assert_receive {:workflow_resume, resume_request}
    assert resume_request.payload["operator_id"] == actor.id
    assert Repo.get!(Profile, profile.id).automation_status == "leased"

    assert %Session{mode: "automation", status: "ready", lease_id: nil} =
             Repo.get!(Session, remote_execution_id)
  end

  test "workflow session reconciliation rejects a central identity collision without changing authority" do
    actor = actor_fixture()
    other_actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node, %{automation_status: "leased"})
    remote_execution_id = Ecto.UUID.generate()

    %Session{id: ^remote_execution_id} =
      %Session{id: remote_execution_id}
      |> Session.changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        remote_session_id: Ecto.UUID.generate(),
        mode: "automation",
        status: "ready",
        owner_actor_id: other_actor.id,
        expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
      })
      |> Repo.insert!()

    job =
      job_fixture(actor, node, profile, %{
        status: "waiting_human",
        remote_execution_id: remote_execution_id,
        idempotency_key: "session-identity-collision"
      })

    reconcile = fn request ->
      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "central_job_id" => job.id,
           "remote_execution_id" => remote_execution_id,
           "remote_session_id" => Ecto.UUID.generate(),
           "status" => "waiting_human",
           "phase" => "login_required",
           "last_sequence" => 2,
           "artifacts" => [],
           "outbox" => %{"pending_artifact_count" => 0}
         }
       }}
    end

    assert {:error, :session_mismatch} =
             Browser.reconcile_job_id(job.id, dispatch: reconcile)

    assert Repo.get!(Job, job.id).session_id == nil
    assert Repo.get!(Profile, profile.id).automation_status == "leased"
  end

  test "an accepted dispatch binds the durable remote execution ID" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    job = job_fixture(actor, node, profile)
    remote_id = Ecto.UUID.generate()

    dispatch = fn request ->
      {:ok,
       %RPCAccepted{
         protocol_version: 1,
         request_id: request.request_id,
         remote_execution_id: remote_id
       }}
    end

    assert {:ok, %Job{status: "accepted", remote_execution_id: ^remote_id}} =
             Browser.dispatch_job(job.id, dispatch: dispatch)
  end

  test "create through intervention resumes with the same actor and atomically reacquires its profile" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    parent = self()

    channel = spawn_link(fn -> workflow_control_loop(node.commander_id, parent) end)

    {:ok, generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        channel,
        %{capability_descriptors: [%{"id" => "browser.control", "version" => 1}]},
        {:workflow_resume_test, make_ref()}
      )

    on_exit(fn -> AgentRegistry.unregister_agent(node.commander_id, channel, generation) end)

    assert {:ok, %Job{} = created} =
             Browser.create_job(actor, %{
               node_id: node.id,
               profile_id: profile.id,
               workflow: "gemini.deep_research",
               workflow_version: 1,
               input: deep_input("resume after intervention"),
               output_formats: output_formats(),
               idempotency_key: "resume-authority"
             })

    remote_id = Ecto.UUID.generate()

    dispatch = fn request ->
      {:ok,
       %RPCAccepted{
         protocol_version: 1,
         request_id: request.request_id,
         remote_execution_id: remote_id
       }}
    end

    assert {:ok, %Job{status: "accepted"}} = Browser.dispatch_job(created.id, dispatch: dispatch)

    event = fn sequence, name ->
      %GSMLG.Commander.Protocol.JobEvent{
        protocol_version: 1,
        remote_execution_id: remote_id,
        sequence: sequence,
        event: name,
        phase: "researching",
        metadata: %{"central_job_id" => created.id},
        occurred_at: DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end

    assert {:ok, _} =
             GSMLG.Browser.EventStore.ingest(
               node.commander_id,
               event.(1, "workflow.started"),
               ack: fn _agent, _ack -> :ok end
             )

    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, _} =
               GSMLG.Browser.EventStore.ingest(
                 node.commander_id,
                 event.(2, "intervention.required"),
                 ack: fn _agent, _ack -> :ok end
               )
    end)

    assert %Job{status: "waiting_human"} = Repo.get!(Job, created.id)
    assert %Profile{automation_status: "manual"} = Repo.get!(Profile, profile.id)

    assert {:ok, %Job{status: "running"}} = Browser.resume_job(actor, created.id)
    assert_receive {:workflow_resume, request}
    assert request.payload["central_job_id"] == created.id
    assert request.payload["remote_execution_id"] == remote_id
    assert request.payload["operator_id"] == actor.id
    assert %Profile{automation_status: "leased"} = Repo.get!(Profile, profile.id)
  end

  test "validates both exact workflow inputs and rejects unknown public fields before persistence" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    base = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.youtube_analysis",
      workflow_version: 1,
      input: %{
        "youtube_url" => "https://www.youtube.com/watch?v=abcdef",
        "analysis_profile" => "technical_review",
        "output_locale" => "en-US",
        "custom_instructions" => "Focus on evidence.",
        "use_deep_research" => false
      },
      output_formats: output_formats(),
      idempotency_key: "youtube-valid"
    }

    assert {:ok, %Job{}} = Browser.create_job(actor, base)

    invalid_deep =
      base
      |> Map.put(:idempotency_key, "bad-deep")
      |> Map.put(:workflow, "gemini.deep_research")
      |> Map.put(:input, %{"prompt" => "missing exact required fields"})

    assert {:error, %Error{code: "invalid_workflow_input"}} =
             Browser.create_job(actor, invalid_deep)

    unknown =
      base |> Map.put(:idempotency_key, "unknown") |> Map.put(:deadline_at, DateTime.utc_now())

    assert {:error, %Error{code: "invalid_request"}} = Browser.create_job(actor, unknown)
  end

  test "same actor and idempotency key with a changed fingerprint conflicts" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    attrs = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      input: deep_input("original"),
      output_formats: output_formats(),
      idempotency_key: "fingerprint"
    }

    assert {:ok, %Job{}} = Browser.create_job(actor, attrs)

    assert {:error, %Error{code: "idempotency_conflict"}} =
             Browser.create_job(actor, put_in(attrs, [:input, "prompt"], "changed"))
  end

  test "a failed Oban insertion rolls back the job and profile lease" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)

    Repo.query!("""
    ALTER TABLE oban_jobs
    ADD CONSTRAINT browser_test_reject_dispatch
    CHECK (worker <> 'GSMLG.Browser.Workers.DispatchWorker')
    """)

    attrs = %{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      input: deep_input("rollback"),
      output_formats: output_formats(),
      idempotency_key: "rollback"
    }

    assert {:error, %Error{}} = Browser.create_job(actor, attrs)
    refute Repo.get_by(Job, requested_by_actor_id: actor.id, idempotency_key: "rollback")
    assert Repo.get!(Profile, profile.id).automation_status == "available"
  end

  test "resolves the configured node and its single default profile when IDs are omitted" do
    actor = actor_fixture()
    node = online_node_fixture()
    profile = profile_fixture(node)
    previous = Application.get_env(:gsmlg_browser, :default_node)
    Application.put_env(:gsmlg_browser, :default_node, node.commander_id)
    on_exit(fn -> Application.put_env(:gsmlg_browser, :default_node, previous) end)

    assert {:ok, %Job{node_id: node_id, profile_id: profile_id}} =
             Browser.create_job(actor, %{
               workflow: "gemini.deep_research",
               workflow_version: 1,
               input: deep_input("default"),
               output_formats: output_formats(),
               idempotency_key: "default-resource"
             })

    assert node_id == node.id
    assert profile_id == profile.id
  end

  test "job cursor pagination is stable and capped at 100" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)

    jobs =
      for index <- 1..3 do
        job_fixture(actor, node, profile, %{idempotency_key: "cursor-#{index}"})
      end
      |> Enum.sort_by(& &1.id)

    assert {:ok, [first]} = Browser.list_jobs(actor, limit: 1)
    assert first.id == hd(jobs).id
    assert {:ok, rest} = Browser.list_jobs(actor, after: first.id, limit: 500)
    assert Enum.map(rest, & &1.id) == Enum.map(tl(jobs), & &1.id)
  end

  test "session listing is actor scoped and cursor bounded" do
    actor = actor_fixture()
    other = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)

    sessions =
      for owner <- [actor, actor, other] do
        %Session{}
        |> Session.changeset(%{
          node_id: node.id,
          profile_id: profile.id,
          mode: "automation",
          status: "ready",
          owner_actor_id: owner.id,
          expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        })
        |> Repo.insert!()
      end

    owned = sessions |> Enum.filter(&(&1.owner_actor_id == actor.id)) |> Enum.sort_by(& &1.id)
    assert {:ok, [first]} = Browser.list_sessions(actor, limit: 1)
    assert first.id == hd(owned).id
    assert {:ok, [second]} = Browser.list_sessions(actor, after: first.id, limit: 500)
    assert second.id == List.last(owned).id
  end

  test "a queued cancellation is local, terminal, and releases the profile" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node, %{automation_status: "leased"})
    job = job_fixture(actor, node, profile)

    assert {:ok, %Job{status: "cancelled", completed_at: %DateTime{}}} =
             Browser.cancel_job(actor, job.id)

    assert Repo.get!(Profile, profile.id).automation_status == "available"
  end

  test "retry refuses to exceed the configured linear attempt limit" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    first = job_fixture(actor, node, profile, %{status: "failed"})

    exhausted =
      job_fixture(actor, node, profile, %{
        status: "failed",
        attempt: 3,
        previous_job_id: first.id,
        idempotency_key: "attempt-three"
      })

    assert {:error, %Error{code: "max_attempts_exceeded"}} =
             Browser.retry_job(actor, exhausted.id, "attempt-four")

    refute Repo.get_by(Job, previous_job_id: exhausted.id)
  end

  test "public IDs and cursors fail as typed errors instead of raising Ecto cast exceptions" do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    job = job_fixture(actor, node, profile)

    assert {:error, %Error{code: "invalid_request"}} = Browser.get_job(actor, "not-a-uuid")

    assert {:error, %Error{code: "invalid_request"}} =
             Browser.list_jobs(actor, after: "not-a-uuid")

    assert {:error, %Error{code: "invalid_request"}} =
             Browser.list_job_events(actor, job.id, after_sequence: -1)
  end

  defp deep_input(prompt) do
    %{
      "prompt" => prompt,
      "output_locale" => "en-US",
      "research_scope" => "Public technical sources",
      "required_sections" => ["Summary", "Evidence"],
      "auto_approve_plan" => true
    }
  end

  defp output_formats, do: ["report.markdown", "report.json", "sources.json"]

  defp online_node_fixture(attrs \\ %{}) do
    node = node_fixture(attrs)

    {:ok, _generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        self(),
        %{
          capability_descriptors: [
            %{"id" => "browser.control", "version" => 1, "backend" => "cloakbrowser"}
          ]
        },
        {:browser_context_test, make_ref()}
      )

    node
  end

  defp workflow_control_loop(agent_id, parent) do
    receive do
      {:commander_rpc, wire} ->
        {:ok, request} = Envelope.decode(wire)
        send(parent, {:workflow_resume, request})

        response = %RPCResponse{
          protocol_version: 1,
          request_id: request.request_id,
          result: %{
            "central_job_id" => request.payload["central_job_id"],
            "remote_execution_id" => request.payload["remote_execution_id"],
            "status" => "running",
            "phase" => "researching"
          }
        }

        :ok = RPCDispatcher.route_incoming(agent_id, response)
        workflow_control_loop(agent_id, parent)
    end
  end

  defp workflow_manual_loop(agent_id, parent, central_session_id, profile_id, actor_id) do
    receive do
      {:commander_rpc, wire} ->
        {:ok, request} = Envelope.decode(wire)

        result =
          case request.operation do
            "session.manual_acquire" ->
              send(parent, {:workflow_manual_acquire, request})

              %{
                "central_session_id" => central_session_id,
                "remote_session_id" => request.payload["session_id"],
                "profile_id" => profile_id,
                "status" => "waiting_human",
                "lease_id" => Ecto.UUID.generate(),
                "lease_owner_type" => "manual",
                "lease_owner_id" => actor_id
              }

            "workflow.resume" ->
              send(parent, {:workflow_resume, request})

              %{
                "central_job_id" => request.payload["central_job_id"],
                "remote_execution_id" => request.payload["remote_execution_id"],
                "status" => "running",
                "phase" => "researching"
              }
          end

        response = %RPCResponse{
          protocol_version: 1,
          request_id: request.request_id,
          result: result
        }

        :ok = RPCDispatcher.route_incoming(agent_id, response)

        workflow_manual_loop(agent_id, parent, central_session_id, profile_id, actor_id)
    end
  end
end
