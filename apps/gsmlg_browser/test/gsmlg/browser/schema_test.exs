defmodule GSMLG.Browser.SchemaTest do
  use GSMLG.Browser.DataCase, async: true

  alias GSMLG.Browser.{Artifact, Job, JobEvent, Node, Profile, Session}

  test "persists the central browser graph with actor-scoped job idempotency" do
    actor = actor_fixture()

    node =
      %Node{}
      |> Node.changeset(%{
        commander_id: "browser-node-1",
        status: "offline",
        default_backend: "cloakbrowser"
      })
      |> Repo.insert!()

    profile =
      %Profile{}
      |> Profile.changeset(%{
        node_id: node.id,
        external_id: "profile-1",
        name: "Research",
        backend: "cloakbrowser",
        is_default: true
      })
      |> Repo.insert!()

    session =
      %Session{}
      |> Session.changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        remote_session_id: Ecto.UUID.generate(),
        lease_id: Ecto.UUID.generate(),
        mode: "automation",
        status: "ready",
        origin_policy: %{"allowed_origins" => ["https://gemini.google.com"]},
        owner_actor_id: actor.id,
        revision: 1,
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
      |> Repo.insert!()

    job =
      %Job{}
      |> Job.create_changeset(%{
        node_id: node.id,
        profile_id: profile.id,
        session_id: session.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "queued",
        input: %{"prompt" => "Research OTP"},
        output_formats: ["report.markdown"],
        idempotency_key: "actor-job-1",
        requested_by_actor_id: actor.id,
        deadline_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      })
      |> Repo.insert!()

    event =
      %JobEvent{}
      |> JobEvent.changeset(%{
        job_id: job.id,
        remote_execution_id: Ecto.UUID.generate(),
        sequence: 1,
        event: "workflow.started",
        metadata: %{"central_job_id" => job.id}
      })
      |> Repo.insert!()

    artifact =
      %Artifact{id: Ecto.UUID.generate()}
      |> Artifact.manifest_changeset(%{
        job_id: job.id,
        kind: "report.markdown",
        mime: "text/markdown",
        filename: "report.md",
        size: 7,
        sha256: :crypto.hash(:sha256, "# report") |> Base.encode16(case: :lower),
        transfer_mode: "inline",
        status: "pending",
        metadata: %{}
      })
      |> Repo.insert!()

    assert %{profile_id: profile_id, owner_actor_id: actor_id} = session
    assert profile_id == profile.id
    assert actor_id == actor.id
    assert %{job_id: job_id, sequence: 1} = event
    assert job_id == job.id
    assert %{job_id: artifact_job_id, status: "pending"} = artifact
    assert artifact_job_id == job.id

    session_artifact =
      %Artifact{id: Ecto.UUID.generate()}
      |> Artifact.manifest_changeset(%{
        session_id: session.id,
        kind: "screenshot.png",
        mime: "image/png",
        filename: "screenshot.png",
        size: 3,
        sha256: :crypto.hash(:sha256, "png") |> Base.encode16(case: :lower),
        transfer_mode: "remote_pending",
        status: "pending",
        metadata: %{"remote_session_id" => session.remote_session_id}
      })
      |> Repo.insert!()

    assert %{job_id: nil, session_id: session_id} = session_artifact
    assert session_id == session.id

    duplicate =
      Job.create_changeset(%Job{}, %{
        node_id: node.id,
        profile_id: profile.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "queued",
        input: %{},
        output_formats: [],
        idempotency_key: job.idempotency_key,
        requested_by_actor_id: actor.id,
        deadline_at: job.deadline_at
      })

    assert {:error, changeset} = Repo.insert(duplicate)
    assert "has already been taken" in errors_on(changeset).idempotency_key
  end

  test "changesets reject illegal states, invalid sequences, and malformed transfer metadata" do
    refute Job.create_changeset(%Job{}, %{status: "invented"}).valid?
    refute Session.changeset(%Session{}, %{status: "invented"}).valid?
    refute Node.changeset(%Node{}, %{status: "invented"}).valid?
    refute JobEvent.changeset(%JobEvent{}, %{sequence: 0}).valid?

    refute Artifact.manifest_changeset(%Artifact{}, %{
             transfer_mode: "raw_socket",
             sha256: "nope"
           }).valid?

    common = %{
      kind: "download",
      mime: "application/octet-stream",
      filename: "download.bin",
      size: 1,
      sha256: String.duplicate("a", 64),
      transfer_mode: "remote_pending",
      status: "pending"
    }

    refute Artifact.manifest_changeset(%Artifact{}, common).valid?

    refute Artifact.manifest_changeset(
             %Artifact{},
             Map.merge(common, %{job_id: Ecto.UUID.generate(), session_id: Ecto.UUID.generate()})
           ).valid?
  end

  test "database permits only one default profile per node and linear retry child" do
    actor = actor_fixture()
    node = insert_node("browser-node-default")
    first = insert_profile(node, "profile-a", true)

    duplicate_default =
      Profile.changeset(%Profile{}, %{
        node_id: node.id,
        external_id: "profile-b",
        name: "Second",
        backend: "cloakbrowser",
        is_default: true
      })

    assert {:error, changeset} = Repo.insert(duplicate_default)
    assert "has already been taken" in errors_on(changeset).is_default

    original = insert_job(actor, node, first, "first-attempt", nil, 1)
    _retry = insert_job(actor, node, first, "retry-attempt", original.id, 2)

    duplicate_child =
      Job.create_changeset(%Job{}, %{
        node_id: node.id,
        profile_id: first.id,
        workflow: "gemini.deep_research",
        workflow_version: 1,
        status: "queued",
        input: %{},
        output_formats: [],
        idempotency_key: "other-retry",
        requested_by_actor_id: actor.id,
        previous_job_id: original.id,
        attempt: 2,
        deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    assert {:error, retry_changeset} = Repo.insert(duplicate_child)
    assert "has already been taken" in errors_on(retry_changeset).previous_job_id
  end

  defp insert_node(commander_id) do
    %Node{}
    |> Node.changeset(%{
      commander_id: commander_id,
      status: "offline",
      default_backend: "cloakbrowser"
    })
    |> Repo.insert!()
  end

  defp insert_profile(node, external_id, default?) do
    %Profile{}
    |> Profile.changeset(%{
      node_id: node.id,
      external_id: external_id,
      name: external_id,
      backend: "cloakbrowser",
      is_default: default?
    })
    |> Repo.insert!()
  end

  defp insert_job(actor, node, profile, key, previous_job_id, attempt) do
    %Job{}
    |> Job.create_changeset(%{
      node_id: node.id,
      profile_id: profile.id,
      workflow: "gemini.deep_research",
      workflow_version: 1,
      status: "queued",
      input: %{},
      output_formats: [],
      idempotency_key: key,
      requested_by_actor_id: actor.id,
      previous_job_id: previous_job_id,
      attempt: attempt,
      deadline_at: DateTime.add(DateTime.utc_now(), 60, :second)
    })
    |> Repo.insert!()
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
