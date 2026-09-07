defmodule GSMLG.Browser.ArtifactServiceTest do
  use GSMLG.Browser.DataCase, async: true

  alias GSMLG.Browser
  alias GSMLG.Browser.{Artifact, ArtifactService, Session}
  alias GSMLG.Browser.Workers.ArtifactAckWorker
  alias GSMLG.Commander.Protocol.{ArtifactManifest, RPCResponse}

  defmodule FakeStorage do
    def prepare_upload(tenant, type, attrs, _opts) do
      id = Ecto.UUID.generate()

      Process.put(
        {__MODULE__, id},
        Map.merge(attrs, %{tenant: tenant, type: type, content: <<>>})
      )

      {:ok, %{id: id}}
    end

    def write_upload(id, chunk) do
      reservation = Process.get({__MODULE__, id})
      content = reservation.content <> chunk

      if byte_size(content) <= reservation.size do
        Process.put({__MODULE__, id}, %{reservation | content: content})
        :ok
      else
        {:error, :upload_too_large}
      end
    end

    def finalize_upload(id, _opts) do
      reservation = Process.get({__MODULE__, id})
      hash = :crypto.hash(:sha256, reservation.content) |> Base.encode16(case: :lower)

      if byte_size(reservation.content) == reservation.size and hash == reservation.checksum do
        send(self(), {:storage_finalized, id, reservation.content})
        {:ok, %{id: id}}
      else
        {:error, :upload_integrity_failed}
      end
    end

    def reject_upload(id) do
      send(self(), {:storage_rejected, id})
      Process.delete({__MODULE__, id})
      {:ok, :rejected}
    end

    def stream(_id), do: {:ok, "stored-content"}

    def read_range(_id, first, last),
      do: {:ok, binary_part("stored-content", first, last - first + 1)}
  end

  setup do
    actor = actor_fixture()
    node = node_fixture()
    profile = profile_fixture(node)
    remote_id = Ecto.UUID.generate()
    job = job_fixture(actor, node, profile, %{status: "running", remote_execution_id: remote_id})
    %{actor: actor, node: node, job: job, remote_id: remote_id}
  end

  test "inline artifacts enforce the whole encoded ceiling, matrix, ownership, and exact integrity",
       ctx do
    content = "# Verified report\n"
    manifest = manifest(ctx, content, "report.markdown", "text/markdown", "report.md", "inline")

    ack = fn job, artifact ->
      assert Repo.get!(Artifact, artifact.id).status == "verified"
      assert job.id == ctx.job.id
      send(self(), {:acked, artifact.id, artifact.sha256})
      :ok
    end

    assert {:ok, %Artifact{status: "verified", inline_content: ^content} = artifact} =
             ArtifactService.ingest_inline(
               ctx.node.commander_id,
               manifest,
               Base.encode64(content),
               ack: ack
             )

    assert_received {:acked, artifact_id, _hash}
    assert artifact_id == artifact.id

    wrong_mime = %{manifest | artifact_id: Ecto.UUID.generate(), mime: "text/html"}

    assert {:error, :invalid_artifact_type} =
             ArtifactService.ingest_inline(
               ctx.node.commander_id,
               wrong_mime,
               Base.encode64(content),
               ack: ack
             )

    wrong_hash = %{
      manifest
      | artifact_id: Ecto.UUID.generate(),
        sha256: String.duplicate("0", 64)
    }

    assert {:error, :artifact_integrity_failed} =
             ArtifactService.ingest_inline(
               ctx.node.commander_id,
               wrong_hash,
               Base.encode64(content),
               ack: ack
             )

    oversized = :binary.copy(<<0>>, 100_000)

    too_large =
      manifest(ctx, oversized, "report.json", "application/json", "report.json", "inline")

    assert {:error, :inline_artifact_too_large} =
             ArtifactService.ingest_inline(
               ctx.node.commander_id,
               too_large,
               Base.encode64(oversized),
               ack: ack
             )
  end

  test "download media policy matches the finite CDP MIME and extension matrix", ctx do
    for {mime, extension} <- [
          {"application/octet-stream", ".bin"},
          {"application/pdf", ".pdf"},
          {"application/json", ".json"},
          {"text/html", ".html"},
          {"text/markdown", ".md"},
          {"text/plain", ".txt"},
          {"image/png", ".png"},
          {"image/jpeg", ".jpg"},
          {"image/jpeg", ".jpeg"}
        ] do
      content = "safe download"

      manifest =
        manifest(ctx, content, "download", mime, "download#{extension}", "remote_pending")

      assert {:ok, %Artifact{mime: ^mime, filename: "download" <> ^extension}} =
               ArtifactService.register_pending(ctx.node.commander_id, manifest)
    end

    for {mime, filename} <- [
          {"application/json", "download.txt"},
          {"application/octet-stream", "download.zip"},
          {"application/zip", "download.bin"}
        ] do
      manifest = manifest(ctx, "unsafe download", "download", mime, filename, "remote_pending")

      assert {:error, :invalid_artifact_type} =
               ArtifactService.register_pending(ctx.node.commander_id, manifest)
    end
  end

  test "signed upload is HTTPS PUT bound to expiry, headers, artifact, size, and hash", ctx do
    content = ~s({"report":"verified"})

    manifest =
      manifest(ctx, content, "report.json", "application/json", "report.json", "signed_upload")

    assert {:ok, %Artifact{status: "uploading"} = artifact, target} =
             ArtifactService.prepare_upload(ctx.node.commander_id, manifest,
               storage: FakeStorage,
               upload_base_url: "https://admin.example.test/browser-artifact-uploads"
             )

    assert target.method == "PUT"
    assert URI.parse(target.url).scheme == "https"
    refute URI.parse(target.url).query
    assert target.follow_redirects == false
    assert target.headers["x-browser-upload-token"] == target.token
    refute inspect(artifact) =~ target.token
    refute Repo.get!(Artifact, artifact.id).upload_token_digest == target.token

    headers = target.headers

    ack = fn _job, verified ->
      assert Repo.get!(Artifact, verified.id).status == "verified"
      send(self(), {:acked, verified.id})
      :ok
    end

    assert {:error, :invalid_upload_token} =
             ArtifactService.begin_upload(artifact.id, "wrong", headers, storage: FakeStorage)

    assert {:ok, handle} =
             ArtifactService.begin_upload(artifact.id, target.token, headers,
               storage: FakeStorage
             )

    assert :ok = ArtifactService.write_upload_chunk(handle, content)

    assert {:ok, %Artifact{status: "verified", storage_type: "storage"} = verified} =
             ArtifactService.finish_upload(handle, ack: ack)

    assert_received {:storage_finalized, _reservation, ^content}
    assert_received {:acked, verified_id}
    assert verified_id == verified.id
  end

  test "mismatched upload is rejected, cleaned, and never ACKed", ctx do
    content = "# Expected\n"

    manifest =
      manifest(ctx, content, "report.markdown", "text/markdown", "report.md", "signed_upload")

    {:ok, artifact, target} =
      ArtifactService.prepare_upload(ctx.node.commander_id, manifest,
        storage: FakeStorage,
        upload_base_url: "https://admin.example.test/browser-artifact-uploads"
      )

    ack = fn _job, _artifact -> send(self(), :acked) end

    assert {:ok, handle} =
             ArtifactService.begin_upload(artifact.id, target.token, target.headers,
               storage: FakeStorage
             )

    assert :ok = ArtifactService.write_upload_chunk(handle, "X Expected\n")
    assert {:error, :artifact_integrity_failed} = ArtifactService.finish_upload(handle, ack: ack)

    assert Repo.get!(Artifact, artifact.id).status == "rejected"
    assert_received {:storage_rejected, _reservation}
    refute_received :acked
    refute_received {:storage_finalized, _, _}
  end

  test "artifact metadata is bounded/redacted and only verified artifacts can be opened by owner",
       ctx do
    content = "# Private\n"

    bad =
      ctx
      |> manifest(content, "report.markdown", "text/markdown", "report.md", "inline")
      |> Map.put(:metadata, %{"page_url" => "https://secret.invalid"})

    assert {:error, :sensitive_metadata} =
             ArtifactService.ingest_inline(ctx.node.commander_id, bad, Base.encode64(content))

    pending =
      manifest(ctx, content, "report.markdown", "text/markdown", "report.md", "remote_pending")

    assert {:ok, %Artifact{} = artifact} =
             ArtifactService.register_pending(ctx.node.commander_id, pending)

    assert {:error, %Browser.Error{code: "artifact_not_verified"}} =
             Browser.open_artifact(ctx.actor, artifact.id)

    other = actor_fixture()
    assert {:error, %Browser.Error{code: "not_found"}} = Browser.get_artifact(other, artifact.id)

    Repo.update_all(from(item in Artifact, where: item.id == ^artifact.id),
      set: [status: "verified"]
    )

    assert {:error, %Browser.Error{code: "artifact_not_verified"}} =
             Browser.open_artifact(ctx.actor, artifact.id)
  end

  test "remote-pending inline transfer verifies content and ACKs only after commit", ctx do
    content = "# Deferred report\n"

    manifest =
      manifest(ctx, content, "report.markdown", "text/markdown", "report.md", "remote_pending")

    assert {:ok, %Artifact{status: "pending"} = pending} =
             ArtifactService.register_pending(ctx.node.commander_id, manifest)

    dispatch = fn request ->
      send(self(), {:artifact_fetch, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "artifact_id" => pending.id,
           "sha256" => pending.sha256,
           "content_base64" => Base.encode64(content)
         }
       }}
    end

    ack = fn _job, verified ->
      assert Repo.get!(Artifact, verified.id).status == "verified"
      send(self(), :deferred_acked)
      :ok
    end

    assert {:ok, %Artifact{status: "verified", ack_status: "acked"}} =
             ArtifactService.transfer_pending(pending, dispatch: dispatch, ack: ack)

    assert_received {:artifact_fetch, request}
    assert request.operation == "artifact.fetch_inline"

    assert request.payload == %{
             "artifact_id" => pending.id,
             "central_job_id" => ctx.job.id,
             "remote_execution_id" => ctx.remote_id
           }

    assert_received :deferred_acked
  end

  test "session-owned remote-pending artifact transfers, ACKs, and enforces actor ownership",
       ctx do
    remote_session_id = Ecto.UUID.generate()

    session =
      %Session{}
      |> Session.changeset(%{
        node_id: ctx.node.id,
        profile_id: ctx.job.profile_id,
        remote_session_id: remote_session_id,
        lease_id: Ecto.UUID.generate(),
        mode: "automation",
        status: "ready",
        revision: 2,
        origin_policy: %{"authorized_origins" => ["https://gemini.google.com"]},
        owner_actor_id: ctx.actor.id,
        expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      })
      |> Repo.insert!()

    content = ~s({"result":"complete"})

    manifest = %ArtifactManifest{
      protocol_version: 1,
      artifact_id: Ecto.UUID.generate(),
      session_id: session.id,
      kind: "download",
      mime: "application/json",
      filename: "report_.json",
      size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      transfer_mode: "remote_pending",
      metadata: %{
        "remote_session_id" => remote_session_id,
        "source_origin" => "https://gemini.google.com"
      }
    }

    assert {:ok, %Artifact{job_id: nil, session_id: session_id, status: "pending"} = pending} =
             ArtifactService.register_pending(ctx.node.commander_id, manifest)

    assert session_id == session.id

    dispatch = fn request ->
      send(self(), {:session_artifact_fetch, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{
           "artifact_id" => pending.id,
           "sha256" => pending.sha256,
           "content_base64" => Base.encode64(content)
         }
       }}
    end

    ack = fn owner, verified ->
      assert owner.id == session.id
      assert Repo.get!(Artifact, verified.id).status == "verified"
      :ok
    end

    assert {:ok, %Artifact{status: "verified", ack_status: "acked"} = verified} =
             ArtifactService.transfer_pending(pending, dispatch: dispatch, ack: ack)

    assert_received {:session_artifact_fetch, request}

    assert request.payload == %{
             "artifact_id" => pending.id,
             "central_session_id" => session.id,
             "remote_session_id" => remote_session_id
           }

    assert {:ok, ^verified} = Browser.get_artifact(ctx.actor, verified.id)
    assert {:ok, %{source: {:inline, ^content}}} = Browser.open_artifact(ctx.actor, verified.id)

    assert {:error, %Browser.Error{code: "not_found"}} =
             Browser.get_artifact(actor_fixture(), verified.id)
  end

  test "failed remote ACK remains durable and succeeds on retry", ctx do
    content = ~s({"verified":true})
    manifest = manifest(ctx, content, "report.json", "application/json", "report.json", "inline")

    artifact =
      Oban.Testing.with_testing_mode(:manual, fn ->
        assert {:ok, %Artifact{ack_status: "pending", ack_attempts: 1} = artifact} =
                 ArtifactService.ingest_inline(
                   ctx.node.commander_id,
                   manifest,
                   Base.encode64(content),
                   ack: fn _job, _artifact -> {:error, :node_offline} end
                 )

        assert Repo.get_by!(Oban.Job,
                 worker: inspect(ArtifactAckWorker),
                 args: %{"artifact_id" => artifact.id}
               )

        artifact
      end)

    assert {:ok, %Artifact{ack_status: "acked", ack_attempts: 1}} =
             ArtifactService.retry_ack(artifact, ack: fn _job, _artifact -> :ok end)
  end

  test "large remote-pending artifacts receive the frozen required_headers upload contract",
       ctx do
    content = String.duplicate("x", 100_000)

    manifest =
      manifest(
        ctx,
        content,
        "download",
        "application/octet-stream",
        "result.bin",
        "remote_pending"
      )

    assert {:ok, %Artifact{status: "pending"} = pending} =
             ArtifactService.register_pending(ctx.node.commander_id, manifest)

    dispatch = fn request ->
      send(self(), {:artifact_upload, request})

      {:ok,
       %RPCResponse{
         protocol_version: 1,
         request_id: request.request_id,
         result: %{"artifact_id" => pending.id, "status" => "uploaded"}
       }}
    end

    assert {:ok, %Artifact{status: "uploading"}} =
             ArtifactService.transfer_pending(pending,
               storage: FakeStorage,
               upload_base_url: "https://admin.example.test/browser-artifact-uploads",
               dispatch: dispatch
             )

    assert_received {:artifact_upload, request}
    assert request.operation == "artifact.upload"
    assert is_map(request.payload["required_headers"])
    assert request.payload["required_headers"]["content-length"] == "100000"
    refute Map.has_key?(request.payload, "headers")
    refute URI.parse(request.payload["upload_url"]).query
  end

  test "an ambiguous upload invalidates the one-use capability and retries with a new generation",
       ctx do
    content = String.duplicate("y", 100_000)

    manifest =
      manifest(
        ctx,
        content,
        "download",
        "application/octet-stream",
        "retry.bin",
        "remote_pending"
      )

    assert {:ok, pending} = ArtifactService.register_pending(ctx.node.commander_id, manifest)

    dispatch = fn request ->
      attempt = Process.get(:upload_attempt, 0) + 1
      Process.put(:upload_attempt, attempt)
      send(self(), {:upload_attempt, attempt, request})

      if attempt == 1 do
        {:error, :rpc_timeout}
      else
        {:ok,
         %RPCResponse{
           protocol_version: 1,
           request_id: request.request_id,
           result: %{"artifact_id" => pending.id, "status" => "uploaded"}
         }}
      end
    end

    opts = [
      storage: FakeStorage,
      upload_base_url: "https://admin.example.test/browser-artifact-uploads",
      dispatch: dispatch
    ]

    assert {:error, :rpc_timeout} = ArtifactService.transfer_pending(pending, opts)

    assert %Artifact{status: "pending", storage_ref: nil, upload_token_digest: nil} =
             Repo.get!(Artifact, pending.id)

    assert_received {:upload_attempt, 1, first}
    assert_received {:storage_rejected, first_reservation}

    assert {:ok, %Artifact{status: "uploading", storage_ref: second_reservation}} =
             ArtifactService.transfer_pending(Repo.get!(Artifact, pending.id), opts)

    assert_received {:upload_attempt, 2, second}
    refute first_reservation == second_reservation
    refute first.idempotency_key == second.idempotency_key

    refute first.payload["required_headers"]["x-browser-upload-token"] ==
             second.payload["required_headers"]["x-browser-upload-token"]
  end

  test "disconnect after upload claim resets pending and reissues a fresh one-use capability",
       ctx do
    content = String.duplicate("z", 100_000)

    manifest =
      manifest(
        ctx,
        content,
        "download",
        "application/octet-stream",
        "disconnect.bin",
        "remote_pending"
      )

    assert {:ok, pending} = ArtifactService.register_pending(ctx.node.commander_id, manifest)

    disconnect = fn request ->
      token = request.payload["required_headers"]["x-browser-upload-token"]

      assert {:ok, handle} =
               ArtifactService.begin_upload(
                 pending.id,
                 token,
                 request.payload["required_headers"],
                 storage: FakeStorage
               )

      assert :ok = ArtifactService.write_upload_chunk(handle, binary_part(content, 0, 10))
      assert :ok = ArtifactService.abort_upload(handle)
      send(self(), {:disconnected_upload, request})
      {:error, :rpc_timeout}
    end

    opts = [
      storage: FakeStorage,
      upload_base_url: "https://admin.example.test/browser-artifact-uploads",
      dispatch: disconnect
    ]

    assert {:error, :rpc_timeout} = ArtifactService.transfer_pending(pending, opts)

    assert %Artifact{
             status: "pending",
             storage_ref: nil,
             upload_token_digest: nil,
             upload_expires_at: nil
           } = Repo.get!(Artifact, pending.id)

    assert_received {:disconnected_upload, first}

    reissued = fn request ->
      send(self(), {:reissued_upload, request})
      {:error, :rpc_timeout}
    end

    assert {:error, :rpc_timeout} =
             ArtifactService.transfer_pending(
               Repo.get!(Artifact, pending.id),
               Keyword.put(opts, :dispatch, reissued)
             )

    assert_received {:reissued_upload, second}
    refute first.idempotency_key == second.idempotency_key

    refute first.payload["required_headers"]["x-browser-upload-token"] ==
             second.payload["required_headers"]["x-browser-upload-token"]
  end

  defp manifest(ctx, content, kind, mime, filename, transfer_mode) do
    %ArtifactManifest{
      protocol_version: 1,
      artifact_id: Ecto.UUID.generate(),
      job_id: ctx.job.id,
      kind: kind,
      mime: mime,
      filename: filename,
      size: byte_size(content),
      sha256: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
      transfer_mode: transfer_mode,
      metadata: %{"remote_execution_id" => ctx.remote_id}
    }
  end
end
