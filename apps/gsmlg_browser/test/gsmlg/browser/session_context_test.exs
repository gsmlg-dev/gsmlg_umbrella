defmodule GSMLG.Browser.SessionContextTest do
  use GSMLG.Browser.DataCase, async: false

  alias GSMLG.Browser
  alias GSMLG.Browser.{Artifact, Error, Profile, Session}
  alias GSMLG.CommandPlatform.{AgentRegistry, RPCDispatcher}
  alias GSMLG.Commander.Protocol.{Envelope, RPCError, RPCResponse}

  setup do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    test_pid = self()

    channel =
      spawn_link(fn ->
        rpc_loop(node.commander_id, profile.external_id, actor.id, test_pid, %{
          open: :normal,
          action: :normal
        })
      end)

    {:ok, generation} =
      AgentRegistry.activate_agent(
        node.commander_id,
        channel,
        %{capability_descriptors: [%{"id" => "browser.control", "version" => 1}]},
        {:session_context_test, make_ref()}
      )

    on_exit(fn -> AgentRegistry.unregister_agent(node.commander_id, channel, generation) end)

    %{actor: actor, node: node, profile: profile, channel: channel}
  end

  test "create_session requires and preserves explicit node, profile, mode, origins, and TTL",
       ctx do
    assert {:ok, %Session{mode: "manual", status: "waiting_human"} = session} =
             Browser.create_session(ctx.actor, %{
               node_id: ctx.node.id,
               profile_id: ctx.profile.id,
               mode: "manual",
               authorized_origins: ["https://gemini.google.com"],
               ttl_ms: 60_000
             })

    assert_received {:rpc, request}
    assert request.operation == "session.open"
    assert request.payload["central_session_id"] == session.id
    assert request.payload["mode"] == "manual"
    assert request.payload["operator_id"] == ctx.actor.id
    refute Map.has_key?(request.payload, "node_id")
    assert Repo.get!(Profile, ctx.profile.id).automation_status == "manual"

    other_node = node_fixture()

    assert {:error, %Error{code: "profile_node_mismatch"}} =
             Browser.create_session(ctx.actor, %{
               node_id: other_node.id,
               profile_id: ctx.profile.id,
               mode: "automation",
               authorized_origins: ["https://gemini.google.com"],
               ttl_ms: 60_000
             })
  end

  test "public action shape lowers nested input and protects unknown keys and stale revisions",
       ctx do
    session = session_fixture(ctx, revision: 4)

    action = %{
      action_id: "action-1",
      expected_revision: 4,
      type: "fill",
      locator: %{"role" => "textbox", "accessible_name" => "Prompt"},
      input: %{"text" => "safe input"},
      postcondition: %{"type" => "node_present", "locator" => %{"text" => "Submitted"}},
      timeout_ms: 5_000
    }

    assert {:ok, %{session: %Session{revision: 5}}} =
             Browser.execute_action(ctx.actor, session.id, action)

    assert_received {:rpc, request}
    assert request.operation == "session.act"

    assert request.payload == %{
             "session_id" => session.remote_session_id,
             "action" => %{
               "action_id" => "action-1",
               "session_id" => session.remote_session_id,
               "expected_revision" => 4,
               "type" => "fill",
               "locator" => %{"role" => "textbox", "accessible_name" => "Prompt"},
               "text" => "safe input",
               "timeout_ms" => 5_000,
               "preconditions" => [],
               "postcondition" => %{
                 "type" => "node_present",
                 "locator" => %{"text" => "Submitted"}
               }
             }
           }

    assert {:error, %Error{code: "action_not_allowed"}} =
             Browser.execute_action(ctx.actor, session.id, Map.put(action, :unexpected, true))

    assert {:error, %Error{class: "conflict", code: "stale_observation"}} =
             Browser.execute_action(ctx.actor, session.id, %{action | expected_revision: 3})

    refute_received {:rpc, _request}
  end

  test "public open, observe, screenshot, and download durably register only safe artifact references",
       ctx do
    Oban.Testing.with_testing_mode(:manual, fn ->
      assert {:ok, %Session{status: "ready", revision: 0} = session} =
               Browser.create_session(ctx.actor, %{
                 node_id: ctx.node.id,
                 profile_id: ctx.profile.id,
                 mode: "automation",
                 authorized_origins: ["https://gemini.google.com"],
                 ttl_ms: 60_000,
                 permissions: %{"screenshot" => true, "download" => true}
               })

      assert {:ok, %{session: %Session{revision: 1}, observation: observation}} =
               Browser.observe_session(ctx.actor, session.id)

      assert observation["url"] == "https://gemini.google.com/app"

      send(ctx.channel, {:set_action_mode, self(), :artifact})
      assert_receive :action_mode_set

      assert {:ok, %{session: %Session{revision: 2}, result: result}} =
               Browser.execute_action(ctx.actor, session.id, %{
                 action_id: "screenshot-1",
                 expected_revision: 1,
                 type: "screenshot",
                 locator: nil,
                 input: %{},
                 postcondition: nil,
                 timeout_ms: 5_000
               })

      assert %{
               "output" => %{
                 "artifact" => %{
                   "artifact_id" => artifact_id,
                   "kind" => "screenshot.png",
                   "mime" => "image/png",
                   "filename" => "screenshot.png",
                   "size" => 3,
                   "sha256" => sha256,
                   "status" => "pending"
                 }
               }
             } = result

      assert is_binary(sha256)
      refute inspect(result["output"]["artifact"]) =~ "remote_session_id"
      refute inspect(result["output"]["artifact"]) =~ "transfer_mode"
      refute inspect(result["output"]["artifact"]) =~ "inline_content"

      assert %Artifact{session_id: session_id, job_id: nil, status: "pending"} =
               Repo.get!(Artifact, artifact_id)

      assert session_id == session.id
      assert Repo.get_by!(Oban.Job, args: %{"artifact_id" => artifact_id})

      assert {:ok, %{session: %Session{revision: 3}, result: download_result}} =
               Browser.execute_action(ctx.actor, session.id, %{
                 action_id: "download-1",
                 expected_revision: 2,
                 type: "download",
                 locator: %{"node_id" => "download-link"},
                 input: %{},
                 postcondition: nil,
                 timeout_ms: 5_000
               })

      assert %{
               "output" => %{
                 "artifact" => %{
                   "artifact_id" => download_id,
                   "kind" => "download",
                   "mime" => "application/pdf",
                   "filename" => "report_.pdf",
                   "size" => 3,
                   "status" => "pending"
                 }
               }
             } = download_result

      refute inspect(download_result["output"]["artifact"]) =~ "secret=query"

      assert %Artifact{session_id: ^session_id, job_id: nil, status: "pending"} =
               Repo.get!(Artifact, download_id)

      assert Repo.get_by!(Oban.Job, args: %{"artifact_id" => download_id})

      send(ctx.channel, {:set_action_mode, self(), {:artifact_as, "download"}})
      assert_receive :action_mode_set

      assert {:error, %Error{code: "action_outcome_unknown"}} =
               Browser.execute_action(ctx.actor, session.id, %{
                 action_id: "mismatched-screenshot",
                 expected_revision: 3,
                 type: "screenshot",
                 locator: nil,
                 input: %{},
                 postcondition: nil,
                 timeout_ms: 5_000
               })

      assert Repo.aggregate(
               from(artifact in Artifact, where: artifact.session_id == ^session.id),
               :count
             ) == 2
    end)
  end

  test "manual acquire is actor-bound and release retry after a lost caller response is idempotent",
       ctx do
    session = session_fixture(ctx, revision: 1)

    Repo.update_all(from(profile in Profile, where: profile.id == ^ctx.profile.id),
      set: [automation_status: "leased"]
    )

    assert {:ok, %Session{mode: "manual", status: "waiting_human", lease_id: lease_id}} =
             Browser.manual_acquire(ctx.actor, session.id)

    assert_received {:rpc, acquire}
    assert acquire.operation == "session.manual_acquire"

    assert acquire.payload == %{
             "session_id" => session.remote_session_id,
             "operator_id" => ctx.actor.id
           }

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "manual"

    assert {:ok, %Session{lease_id: ^lease_id}} = Browser.manual_acquire(ctx.actor, session.id)
    assert_received {:rpc, %{operation: "session.manual_acquire"}}

    assert {:ok, %Session{mode: "automation", status: "waiting_human", lease_id: nil}} =
             Browser.manual_release(ctx.actor, session.id)

    assert_received {:rpc, release}
    assert release.operation == "session.manual_release"

    assert release.payload == %{
             "session_id" => session.remote_session_id,
             "lease_id" => lease_id,
             "operator_id" => ctx.actor.id
           }

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "manual"

    assert {:ok, %Session{mode: "automation", status: "waiting_human", lease_id: nil}} =
             Browser.manual_release(ctx.actor, session.id)

    refute_received {:rpc, %{operation: "session.manual_release"}}
  end

  test "an invalid open response leaves an orphan for reconciliation and retains the lease",
       ctx do
    send(ctx.channel, {:set_open_mode, self(), :invalid})
    assert_receive :open_mode_set

    assert {:error, %Error{code: "session_outcome_unknown", retryable: false}} =
             Browser.create_session(ctx.actor, %{
               node_id: ctx.node.id,
               profile_id: ctx.profile.id,
               mode: "automation",
               authorized_origins: ["https://gemini.google.com"],
               ttl_ms: 60_000
             })

    assert %Session{status: "orphaned", error: %{"code" => "session_open_outcome_unknown"}} =
             Repo.get_by!(Session, owner_actor_id: ctx.actor.id)

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "leased"
  end

  test "a deterministic remote open error fails the session and releases the profile", ctx do
    send(ctx.channel, {:set_open_mode, self(), :error})
    assert_receive :open_mode_set

    assert {:error, %Error{code: "operation_failed"}} =
             Browser.create_session(ctx.actor, %{
               node_id: ctx.node.id,
               profile_id: ctx.profile.id,
               mode: "automation",
               authorized_origins: ["https://gemini.google.com"],
               ttl_ms: 60_000
             })

    assert %Session{status: "failed", error: %{"code" => "remote_error"}} =
             Repo.get_by!(Session, owner_actor_id: ctx.actor.id)

    assert Repo.get!(Profile, ctx.profile.id).automation_status == "available"
  end

  test "a remote stale observation remains a typed conflict instead of a generic failure", ctx do
    session = session_fixture(ctx, revision: 7)
    send(ctx.channel, {:set_action_mode, self(), :stale})
    assert_receive :action_mode_set

    action = %{
      action_id: "stale-action",
      expected_revision: 7,
      type: "click",
      locator: %{"role" => "button", "accessible_name" => "Submit"},
      input: %{},
      postcondition: nil,
      timeout_ms: 5_000
    }

    assert {:error, %Error{class: "conflict", code: "stale_observation"}} =
             Browser.execute_action(ctx.actor, session.id, action)

    assert %Session{status: "ready", revision: 7} = Repo.get!(Session, session.id)
  end

  defp session_fixture(ctx, opts) do
    %Session{}
    |> Session.changeset(%{
      node_id: ctx.node.id,
      profile_id: ctx.profile.id,
      remote_session_id: Ecto.UUID.generate(),
      lease_id: Ecto.UUID.generate(),
      mode: "automation",
      status: "ready",
      revision: Keyword.fetch!(opts, :revision),
      owner_actor_id: ctx.actor.id,
      origin_policy: %{"authorized_origins" => ["https://gemini.google.com"]},
      expires_at: DateTime.add(DateTime.utc_now(), 600, :second)
    })
    |> Repo.insert!()
  end

  defp rpc_loop(agent_id, profile_id, actor_id, test_pid, modes) do
    receive do
      {:set_open_mode, caller, mode} ->
        send(caller, :open_mode_set)
        rpc_loop(agent_id, profile_id, actor_id, test_pid, %{modes | open: mode})

      {:set_action_mode, caller, mode} ->
        send(caller, :action_mode_set)
        rpc_loop(agent_id, profile_id, actor_id, test_pid, %{modes | action: mode})

      {:commander_rpc, wire} ->
        {:ok, request} = Envelope.decode(wire)
        send(test_pid, {:rpc, request})
        terminal = rpc_terminal(request, profile_id, actor_id, modes)
        :ok = RPCDispatcher.route_incoming(agent_id, terminal)
        rpc_loop(agent_id, profile_id, actor_id, test_pid, modes)
    end
  end

  defp rpc_terminal(
         %{operation: "session.open"} = request,
         _profile_id,
         _actor_id,
         %{open: :error}
       ) do
    %RPCError{
      protocol_version: 1,
      request_id: request.request_id,
      class: "session",
      code: "private_remote_code",
      message: "private remote detail",
      retryable: false,
      human_action: "none",
      details: %{}
    }
  end

  defp rpc_terminal(
         %{operation: "session.act"} = request,
         _profile_id,
         _actor_id,
         %{action: :stale}
       ) do
    %RPCError{
      protocol_version: 1,
      request_id: request.request_id,
      class: "observation",
      code: "stale_observation",
      message: "Stale observation",
      retryable: false,
      human_action: "refresh",
      details: %{}
    }
  end

  defp rpc_terminal(request, profile_id, actor_id, modes) do
    result = rpc_result(request, profile_id, actor_id)

    result =
      if request.operation == "session.open" and modes.open == :invalid,
        do: Map.put(result, "central_session_id", Ecto.UUID.generate()),
        else: result

    result =
      case {request.operation, modes.action} do
        {"session.act", :artifact} ->
          put_action_artifact_manifest(result, request.payload)

        {"session.act", {:artifact_as, type}} ->
          put_action_artifact_manifest(result, put_in(request.payload, ["action", "type"], type))

        _other ->
          result
      end

    %RPCResponse{
      protocol_version: 1,
      request_id: request.request_id,
      result: result
    }
  end

  defp rpc_result(
         %{operation: "session.open", payload: %{"mode" => "manual"} = payload},
         profile_id,
         _actor_id
       ) do
    %{
      "central_session_id" => payload["central_session_id"],
      "remote_session_id" => Ecto.UUID.generate(),
      "profile_id" => profile_id,
      "mode" => "manual",
      "status" => "waiting_human",
      "revision" => 0,
      "lease_id" => Ecto.UUID.generate(),
      "lease_owner_type" => "manual",
      "lease_owner_id" => payload["operator_id"]
    }
  end

  defp rpc_result(%{operation: "session.open", payload: payload}, profile_id, _actor_id) do
    %{
      "central_session_id" => payload["central_session_id"],
      "remote_session_id" => Ecto.UUID.generate(),
      "profile_id" => profile_id,
      "mode" => payload["mode"],
      "status" => "ready",
      "revision" => 0,
      "lease_id" => Ecto.UUID.generate(),
      "lease_owner_type" => "automation",
      "lease_owner_id" => "remote-session"
    }
  end

  defp rpc_result(%{operation: "session.act", payload: payload}, profile_id, _actor_id) do
    %{
      "central_session_id" => central_session_id(payload["session_id"]),
      "remote_session_id" => payload["session_id"],
      "profile_id" => profile_id,
      "status" => "ready",
      "revision" => payload["action"]["expected_revision"] + 1,
      "action_id" => payload["action"]["action_id"]
    }
  end

  defp rpc_result(%{operation: "session.observe", payload: payload}, profile_id, _actor_id) do
    %{
      "central_session_id" => central_session_id(payload["session_id"]),
      "remote_session_id" => payload["session_id"],
      "profile_id" => profile_id,
      "status" => "ready",
      "revision" => 1,
      "url" => "https://gemini.google.com/app",
      "origin" => "https://gemini.google.com",
      "title" => "Gemini",
      "loading_state" => "complete",
      "page_kind" => "gemini",
      "alerts" => [],
      "visible_controls" => [],
      "semantic_tree" => []
    }
  end

  defp rpc_result(%{operation: "session.manual_acquire", payload: payload}, profile_id, actor_id) do
    %{
      "central_session_id" => central_session_id(payload["session_id"]),
      "remote_session_id" => payload["session_id"],
      "profile_id" => profile_id,
      "status" => "waiting_human",
      "lease_id" => manual_lease_id(payload["session_id"]),
      "lease_owner_type" => "manual",
      "lease_owner_id" => actor_id
    }
  end

  defp rpc_result(%{operation: "session.manual_release", payload: payload}, profile_id, actor_id) do
    %{
      "central_session_id" => central_session_id(payload["session_id"]),
      "remote_session_id" => payload["session_id"],
      "profile_id" => profile_id,
      "status" => "waiting_human",
      "lease_id" => nil,
      "lease_owner_type" => "released",
      "lease_owner_id" => actor_id
    }
  end

  defp central_session_id(remote_id) do
    Repo.one!(
      from(session in Session, where: session.remote_session_id == ^remote_id, select: session.id)
    )
  end

  defp put_action_artifact_manifest(result, payload) do
    central_id = central_session_id(payload["session_id"])
    artifact_id = Ecto.UUID.generate()
    {kind, mime, filename, content, metadata} = action_artifact(payload["action"]["type"])

    manifest = %{
      "protocol_version" => 1,
      "artifact_id" => artifact_id,
      "session_id" => central_id,
      "kind" => kind,
      "mime" => mime,
      "filename" => filename,
      "size" => byte_size(content),
      "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      "transfer_mode" => "remote_pending",
      "metadata" => Map.put(metadata, "remote_session_id", payload["session_id"])
    }

    Map.put(result, "output", %{"artifact" => manifest})
  end

  defp action_artifact("screenshot"),
    do: {"screenshot.png", "image/png", "screenshot.png", "png", %{}}

  defp action_artifact("download"),
    do:
      {"download", "application/pdf", "report_.pdf", "pdf",
       %{"source_origin" => "https://gemini.google.com"}}

  defp manual_lease_id(remote_id) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> = :crypto.hash(:sha256, remote_id)

    [a, b, c, d, e]
    |> Enum.zip([8, 4, 4, 4, 12])
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.pad_leading(width, "0")
    end)
  end
end
