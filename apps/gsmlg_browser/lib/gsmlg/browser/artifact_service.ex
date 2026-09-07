defmodule GSMLG.Browser.ArtifactService.UploadHandle do
  @moduledoc false
  @enforce_keys [:artifact_id, :reservation_id, :storage]
  defstruct @enforce_keys
end

defmodule GSMLG.Browser.ArtifactService do
  @moduledoc false

  import Ecto.Query

  alias GSMLG.Browser.ArtifactService.UploadHandle
  alias GSMLG.Browser.Telemetry, as: BrowserTelemetry

  alias GSMLG.Browser.{
    Artifact,
    ArtifactPolicy,
    CommanderBridge,
    Enabled,
    Job,
    Node,
    Notifier,
    Sanitizer,
    Session
  }

  alias GSMLG.Commander.Protocol.ArtifactManifest
  alias GSMLG.Browser.Workers.ArtifactAckWorker
  alias GSMLG.Repo

  @inline_response_limit 131_072
  @metadata_keys ~w(remote_execution_id remote_session_id source_origin width height source_index sequence page_number)

  def ingest_inline(agent_id, manifest, encoded, opts \\ [])

  def ingest_inline(
        agent_id,
        %ArtifactManifest{transfer_mode: "inline"} = manifest,
        encoded,
        opts
      ) do
    with :ok <- Enabled.ensure(),
         :ok <- validate_encoded_ceiling(manifest.artifact_id, encoded),
         {:ok, content} <- decode_content(encoded),
         :ok <- validate_manifest(manifest),
         :ok <- ArtifactPolicy.verify_content(manifest, content),
         {:ok, owner} <- validate_manifest_owner(agent_id, manifest),
         {:ok, artifact} <-
           insert_manifest(manifest, %{
             status: "verified",
             storage_type: "inline",
             inline_content: content,
             verified_at: DateTime.utc_now(),
             ack_status: "pending"
           }) do
      finish_ack(owner, artifact, opts)
    end
  end

  def ingest_inline(_agent_id, _manifest, _encoded, _opts), do: {:error, :invalid_transfer_mode}

  def register_pending(agent_id, %ArtifactManifest{transfer_mode: "remote_pending"} = manifest) do
    with :ok <- Enabled.ensure(),
         {:ok, _owner} <- validate_manifest_owner(agent_id, manifest),
         :ok <- validate_manifest(manifest),
         {:ok, artifact} <-
           insert_manifest(manifest, %{status: "pending", ack_status: "not_ready"}) do
      {:ok, artifact}
    end
  end

  def register_pending(_agent_id, _manifest), do: {:error, :invalid_transfer_mode}

  def prepare_upload(agent_id, manifest, opts \\ [])

  def prepare_upload(agent_id, %ArtifactManifest{transfer_mode: "signed_upload"} = manifest, opts) do
    storage = Keyword.get(opts, :storage, GSMLG.Storage)

    with :ok <- Enabled.ensure(),
         {:ok, _owner} <- validate_manifest_owner(agent_id, manifest),
         :ok <- validate_manifest(manifest),
         {:ok, base_url} <- upload_base_url(opts),
         {:ok, ttl} <- upload_ttl_seconds(opts),
         expires_at <- DateTime.add(DateTime.utc_now(), ttl, :second),
         {:ok, artifact} <- ensure_upload_artifact(manifest, expires_at, storage),
         token <- Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
         {:ok, artifact} <-
           artifact
           |> Artifact.verification_changeset(%{
             upload_token_digest: token_digest(token),
             upload_expires_at: expires_at
           })
           |> Repo.update() do
      target = %{
        method: "PUT",
        url: upload_url(base_url, artifact.id),
        token: token,
        expires_at: expires_at,
        headers: expected_headers(artifact, token),
        follow_redirects: false
      }

      {:ok, artifact, target}
    end
  end

  def prepare_upload(_agent_id, _manifest, _opts), do: {:error, :invalid_transfer_mode}

  def begin_upload(artifact_id, token, headers), do: begin_upload(artifact_id, token, headers, [])

  @doc false
  def begin_upload(artifact_id, token, headers, opts) do
    storage = Keyword.get(opts, :storage, GSMLG.Storage)

    with :ok <- Enabled.ensure() do
      Repo.transaction(fn ->
        artifact =
          Repo.one(from(item in Artifact, where: item.id == ^artifact_id, lock: "FOR UPDATE"))

        with %Artifact{status: "uploading"} = artifact <- artifact,
             :ok <- validate_token(artifact, token),
             :ok <- validate_not_expired(artifact),
             :ok <- validate_headers(artifact, token, headers),
             {:ok, claimed} <-
               artifact
               |> Artifact.verification_changeset(%{upload_token_digest: nil})
               |> Repo.update() do
          %UploadHandle{
            artifact_id: claimed.id,
            reservation_id: claimed.storage_ref,
            storage: storage
          }
        else
          nil -> Repo.rollback(:not_found)
          %Artifact{} -> Repo.rollback(:invalid_artifact_state)
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def write_upload_chunk(%UploadHandle{} = handle, chunk) when is_binary(chunk) do
    with :ok <- Enabled.ensure() do
      case handle.storage.write_upload(handle.reservation_id, chunk) do
        :ok -> :ok
        {:error, _reason} -> {:error, :upload_write_failed}
      end
    end
  end

  def write_upload_chunk(_handle, _chunk), do: {:error, :invalid_upload_handle}

  def finish_upload(handle), do: finish_upload(handle, [])

  @doc false
  def finish_upload(%UploadHandle{} = handle, opts) do
    with :ok <- Enabled.ensure(),
         %Artifact{status: "uploading"} = artifact <- Repo.get(Artifact, handle.artifact_id),
         {:ok, stored} <- handle.storage.finalize_upload(handle.reservation_id, []),
         {:ok, verified} <- mark_verified(artifact, stored),
         owner when not is_nil(owner) <- artifact_owner(verified) do
      finish_ack(owner, verified, opts)
    else
      nil ->
        {:error, :not_found}

      %Artifact{} ->
        {:error, :invalid_artifact_state}

      {:error, _reason} ->
        _ = reject_upload(handle)
        {:error, :artifact_integrity_failed}
    end
  end

  def finish_upload(_handle, _opts), do: {:error, :invalid_upload_handle}

  def abort_upload(%UploadHandle{} = handle) do
    with :ok <- Enabled.ensure() do
      case Repo.get(Artifact, handle.artifact_id) do
        nil ->
          :ok

        %Artifact{status: status} when status in ["verified", "rejected"] ->
          :ok

        %Artifact{status: "uploading", storage_ref: reservation_id} = artifact
        when reservation_id == handle.reservation_id ->
          case reset_pending_upload(artifact, handle.storage) do
            {:ok, _pending} -> :ok
            {:error, _reason} = error -> error
          end

        %Artifact{} ->
          :ok
      end
    end
  end

  def abort_upload(_handle), do: {:error, :invalid_upload_handle}

  defp reject_upload(%UploadHandle{} = handle) do
    _ = handle.storage.reject_upload(handle.reservation_id)

    case Repo.get(Artifact, handle.artifact_id) do
      %Artifact{status: "uploading", storage_ref: reservation_id} = artifact
      when reservation_id == handle.reservation_id ->
        mark_rejected(artifact)

      %Artifact{} ->
        :ok

      nil ->
        :ok
    end
  end

  def retry_ack(artifact, opts \\ [])

  def retry_ack(%Artifact{status: "verified", ack_status: "pending"} = artifact, opts) do
    with :ok <- Enabled.ensure(),
         owner when not is_nil(owner) <- artifact_owner(artifact) do
      finish_ack(owner, artifact, opts)
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  def retry_ack(
        %Artifact{job_id: job_id, status: "verified", ack_status: "acked"} = artifact,
        _opts
      )
      when is_binary(job_id) do
    case GSMLG.Browser.finalize_job_artifacts(artifact.job_id) do
      {:ok, _job} -> {:ok, artifact}
      {:error, _reason} = error -> error
    end
  end

  def retry_ack(%Artifact{status: "verified", ack_status: "acked"} = artifact, _opts),
    do: {:ok, artifact}

  def retry_ack(%Artifact{} = artifact, _opts), do: {:ok, artifact}

  @doc false
  def transfer_pending(artifact, opts \\ [])

  def transfer_pending(
        %Artifact{status: "pending", transfer_mode: "remote_pending"} = artifact,
        opts
      ) do
    BrowserTelemetry.measure_artifact_transfer(artifact, fn ->
      do_transfer_pending(artifact, opts)
    end)
  end

  def transfer_pending(%Artifact{} = artifact, _opts), do: {:ok, artifact}

  defp do_transfer_pending(artifact, opts) do
    with :ok <- Enabled.ensure(),
         owner when not is_nil(owner) <- artifact_owner(artifact),
         %Node{} = node <- Repo.get(Node, owner.node_id) do
      if inline_eligible?(artifact) do
        fetch_pending_inline(owner, node, artifact, opts)
      else
        upload_pending(owner, node, artifact, opts)
      end
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def reset_expired_upload(artifact, opts \\ [])

  def reset_expired_upload(%Artifact{status: "uploading"} = artifact, opts) do
    storage = Keyword.get(opts, :storage, GSMLG.Storage)

    if is_nil(artifact.upload_expires_at) or
         DateTime.compare(artifact.upload_expires_at, DateTime.utc_now()) != :gt do
      reset_pending_upload(artifact, storage)
    else
      {:ok, artifact}
    end
  end

  def reset_expired_upload(%Artifact{} = artifact, _opts), do: {:ok, artifact}

  defp fetch_pending_inline(owner, node, artifact, opts) do
    payload = artifact_identity(owner, artifact)
    deadline = DateTime.add(DateTime.utc_now(), rpc_timeout_ms(), :millisecond)

    with {:ok, result} <-
           CommanderBridge.call(
             node,
             "artifact.fetch_inline",
             payload,
             artifact_operation_key(owner, "artifact.fetch_inline", artifact),
             deadline,
             opts
           ),
         true <-
           is_map(result) and
             Enum.sort(Map.keys(result)) ==
               Enum.sort(~w(artifact_id sha256 content_base64)),
         true <- result["artifact_id"] == artifact.id and result["sha256"] == artifact.sha256,
         :ok <- validate_encoded_result(result),
         {:ok, content} <- decode_content(result["content_base64"]),
         :ok <- ArtifactPolicy.verify_content(artifact, content),
         {:ok, verified} <-
           artifact
           |> Artifact.verification_changeset(%{
             status: "verified",
             storage_type: "inline",
             inline_content: content,
             verified_at: DateTime.utc_now(),
             ack_status: "pending"
           })
           |> Repo.update() do
      finish_ack(owner, verified, opts)
    else
      false -> {:error, :artifact_identity_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp upload_pending(owner, node, artifact, opts) do
    storage = Keyword.get(opts, :storage, GSMLG.Storage)

    with {:ok, uploading, target} <- prepare_pending_upload(artifact, storage, opts),
         payload <-
           artifact_identity(owner, uploading)
           |> Map.merge(%{
             "upload_url" => target.url,
             "required_headers" => target.headers
           }),
         deadline <- DateTime.add(DateTime.utc_now(), rpc_timeout_ms(), :millisecond),
         {:ok, result} <-
           CommanderBridge.call(
             node,
             "artifact.upload",
             payload,
             artifact_operation_key(
               owner,
               "artifact.upload",
               artifact,
               uploading.storage_ref
             ),
             deadline,
             opts
           ),
         true <-
           result == %{"artifact_id" => artifact.id, "status" => "uploaded"} do
      case Repo.get(Artifact, artifact.id) do
        %Artifact{status: "verified"} = verified -> {:ok, verified}
        %Artifact{} = current -> {:ok, current}
        nil -> {:error, :not_found}
      end
    else
      false ->
        recover_upload_failure(owner, artifact, storage, opts, :invalid_rpc_response)

      {:error, reason} ->
        recover_upload_failure(owner, artifact, storage, opts, reason)
    end
  end

  defp recover_upload_failure(owner, artifact, storage, opts, reason) do
    case Repo.get(Artifact, artifact.id) do
      %Artifact{status: "verified", ack_status: "acked"} = verified ->
        {:ok, verified}

      %Artifact{status: "verified"} = verified ->
        finish_ack(owner, verified, opts)

      %Artifact{status: "uploading"} = uploading ->
        case reset_pending_upload(uploading, storage) do
          {:ok, _pending} -> {:error, reason}
          {:error, _reset_reason} -> {:error, :artifact_upload_reset_failed}
        end

      %Artifact{} ->
        {:error, reason}

      nil ->
        {:error, :not_found}
    end
  end

  defp prepare_pending_upload(artifact, storage, opts) do
    with {:ok, base_url} <- upload_base_url(opts),
         {:ok, ttl} <- upload_ttl_seconds(opts),
         expires_at <- DateTime.add(DateTime.utc_now(), ttl, :second),
         {:ok, prepared} <-
           storage.prepare_upload(
             "browser",
             "browser_artifact",
             storage_attrs(artifact, expires_at),
             max_bytes: max_artifact_bytes()
           ),
         reservation_id when is_binary(reservation_id) <- Map.get(prepared, :id),
         token <- Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
         {:ok, uploading} <-
           persist_pending_reservation(
             artifact,
             reservation_id,
             token,
             expires_at,
             storage
           ) do
      target = %{
        method: "PUT",
        url: upload_url(base_url, artifact.id),
        token: token,
        expires_at: expires_at,
        headers: expected_headers(artifact, token),
        follow_redirects: false
      }

      {:ok, uploading, target}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :storage_prepare_failed}
    end
  end

  defp reset_pending_upload(%Artifact{status: "uploading"} = artifact, storage) do
    Repo.transaction(fn ->
      current =
        Repo.one(from(item in Artifact, where: item.id == ^artifact.id, lock: "FOR UPDATE"))

      case current do
        %Artifact{status: "uploading", storage_ref: storage_ref}
        when storage_ref == artifact.storage_ref ->
          case storage.reject_upload(storage_ref) do
            :ok ->
              reset_upload_row(current)

            {:ok, _reservation} ->
              reset_upload_row(current)

            {:error, reason} ->
              Repo.rollback(reason)
          end

        %Artifact{} = latest ->
          latest

        nil ->
          Repo.rollback(:not_found)
      end
    end)
  end

  defp reset_pending_upload(%Artifact{} = artifact, _storage), do: {:ok, artifact}

  defp reset_upload_row(artifact) do
    artifact
    |> Artifact.verification_changeset(%{
      status: "pending",
      storage_type: nil,
      storage_ref: nil,
      upload_token_digest: nil,
      upload_expires_at: nil
    })
    |> Repo.update()
    |> case do
      {:ok, pending} -> pending
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp artifact_identity(%Job{} = job, artifact) do
    %{
      "central_job_id" => job.id,
      "remote_execution_id" => job.remote_execution_id,
      "artifact_id" => artifact.id
    }
  end

  defp artifact_identity(%Session{} = session, artifact) do
    %{
      "central_session_id" => session.id,
      "remote_session_id" => session.remote_session_id,
      "artifact_id" => artifact.id
    }
  end

  defp artifact_operation_key(owner, operation, artifact, generation \\ nil)

  defp artifact_operation_key(%Job{} = job, operation, artifact, generation) do
    Enum.join(
      Enum.reject([job.idempotency_key, operation, artifact.id, generation], &is_nil/1),
      ":"
    )
  end

  defp artifact_operation_key(%Session{} = session, operation, artifact, generation) do
    Enum.join(
      Enum.reject(["session", session.id, operation, artifact.id, generation], &is_nil/1),
      ":"
    )
  end

  defp inline_eligible?(artifact) do
    limit =
      Application.get_env(:gsmlg_browser, :inline_artifact_max_bytes, @inline_response_limit)

    encoded_content = 4 * div(artifact.size + 2, 3)
    encoded_content + 256 <= min(limit, @inline_response_limit)
  end

  defp validate_encoded_result(result) do
    if result |> JSON.encode!() |> byte_size() <= @inline_response_limit,
      do: :ok,
      else: {:error, :inline_artifact_too_large}
  end

  defp ensure_upload_artifact(manifest, expires_at, storage) do
    case Repo.get(Artifact, manifest.artifact_id) do
      nil ->
        with {:ok, prepared} <-
               storage.prepare_upload(
                 "browser",
                 "browser_artifact",
                 storage_attrs(manifest, expires_at),
                 max_bytes: max_artifact_bytes()
               ),
             reservation_id when is_binary(reservation_id) <- Map.get(prepared, :id),
             result <-
               insert_manifest(manifest, %{
                 status: "uploading",
                 storage_type: "storage_reservation",
                 storage_ref: reservation_id,
                 ack_status: "not_ready"
               }) do
          case result do
            {:ok, artifact} ->
              {:ok, artifact}

            {:error, _reason} = error ->
              _ = storage.reject_upload(reservation_id)
              error
          end
        else
          _invalid -> {:error, :storage_prepare_failed}
        end

      %Artifact{status: "uploading"} = existing ->
        if canonical(existing) == canonical_manifest(manifest),
          do: {:ok, existing},
          else: {:error, :artifact_id_conflict}

      %Artifact{} = existing ->
        if canonical(existing) == canonical_manifest(manifest),
          do: {:ok, existing},
          else: {:error, :artifact_id_conflict}
    end
  end

  defp mark_verified(artifact, stored) do
    case Map.get(stored, :id) do
      id when is_binary(id) ->
        Repo.transaction(fn ->
          current =
            Repo.one(from(item in Artifact, where: item.id == ^artifact.id, lock: "FOR UPDATE"))

          case current do
            %Artifact{status: "uploading", storage_ref: ^id} ->
              current
              |> Artifact.verification_changeset(%{
                status: "verified",
                storage_type: "storage",
                storage_ref: id,
                verified_at: DateTime.utc_now(),
                upload_expires_at: nil,
                ack_status: "pending"
              })
              |> Repo.update()
              |> case do
                {:ok, verified} -> verified
                {:error, reason} -> Repo.rollback(reason)
              end

            %Artifact{} ->
              Repo.rollback(:stale_upload_generation)

            nil ->
              Repo.rollback(:not_found)
          end
        end)

      _invalid ->
        {:error, :invalid_storage_result}
    end
  end

  defp persist_pending_reservation(artifact, reservation_id, token, expires_at, storage) do
    result =
      artifact
      |> Artifact.verification_changeset(%{
        status: "uploading",
        storage_type: "storage_reservation",
        storage_ref: reservation_id,
        upload_token_digest: token_digest(token),
        upload_expires_at: expires_at
      })
      |> Repo.update()

    case result do
      {:ok, _artifact} = ok ->
        ok

      {:error, _reason} = error ->
        _ = storage.reject_upload(reservation_id)
        error
    end
  end

  defp mark_rejected(artifact) do
    case artifact
         |> Artifact.verification_changeset(%{
           status: "rejected",
           rejected_at: DateTime.utc_now(),
           upload_token_digest: nil,
           upload_expires_at: nil
         })
         |> Repo.update() do
      {:ok, _artifact} -> :ok
      {:error, _changeset} -> {:error, :upload_abort_failed}
    end
  end

  defp validate_manifest_owner(
         agent_id,
         %ArtifactManifest{job_id: job_id, session_id: nil} = manifest
       )
       when is_binary(job_id) do
    case Repo.one(
           from(job in Job,
             join: node in Node,
             on: node.id == job.node_id,
             where: job.id == ^job_id and node.commander_id == ^agent_id,
             select: job
           )
         ) do
      %Job{remote_execution_id: remote_id} = job when is_binary(remote_id) ->
        if manifest.metadata["remote_execution_id"] == remote_id,
          do: {:ok, job},
          else: {:error, :artifact_owner_mismatch}

      %Job{} ->
        {:error, :job_not_bound}

      nil ->
        {:error, :artifact_owner_mismatch}
    end
  end

  defp validate_manifest_owner(
         agent_id,
         %ArtifactManifest{job_id: nil, session_id: session_id} = manifest
       )
       when is_binary(session_id) do
    case Repo.one(
           from(session in Session,
             join: node in Node,
             on: node.id == session.node_id,
             where: session.id == ^session_id and node.commander_id == ^agent_id,
             select: session
           )
         ) do
      %Session{remote_session_id: remote_id} = session when is_binary(remote_id) ->
        if manifest.metadata["remote_session_id"] == remote_id,
          do: {:ok, session},
          else: {:error, :artifact_owner_mismatch}

      %Session{} ->
        {:error, :session_not_bound}

      nil ->
        {:error, :artifact_owner_mismatch}
    end
  end

  defp validate_manifest_owner(_agent_id, _manifest), do: {:error, :artifact_owner_mismatch}

  defp validate_manifest(manifest) do
    with :ok <- ArtifactPolicy.validate_type(manifest.kind, manifest.mime, manifest.filename),
         true <- Regex.match?(~r/\A[0-9a-f]{64}\z/, manifest.sha256),
         :ok <- Sanitizer.validate_metadata(manifest.metadata, @metadata_keys),
         true <-
           is_integer(manifest.size) and manifest.size >= 0 and
             manifest.size <= max_artifact_bytes() do
      :ok
    else
      false -> {:error, :invalid_artifact}
      {:error, _reason} = error -> error
    end
  end

  defp insert_manifest(manifest, extra) do
    attrs = Map.merge(canonical_manifest(manifest), extra)

    case Repo.get(Artifact, manifest.artifact_id) do
      nil ->
        case %Artifact{} |> Artifact.manifest_changeset(attrs) |> Repo.insert() do
          {:ok, artifact} -> {:ok, artifact}
          {:error, _changeset} -> {:error, :invalid_artifact}
        end

      %Artifact{} = existing ->
        if canonical(existing) == canonical_manifest(manifest),
          do: {:ok, existing},
          else: {:error, :artifact_id_conflict}
    end
  end

  defp canonical_manifest(manifest) do
    %{
      id: manifest.artifact_id,
      job_id: manifest.job_id,
      session_id: manifest.session_id,
      kind: manifest.kind,
      mime: manifest.mime,
      filename: manifest.filename,
      size: manifest.size,
      sha256: manifest.sha256,
      transfer_mode: manifest.transfer_mode,
      metadata: manifest.metadata
    }
  end

  defp canonical(value),
    do:
      Map.take(value, [
        :id,
        :job_id,
        :session_id,
        :kind,
        :mime,
        :filename,
        :size,
        :sha256,
        :transfer_mode,
        :metadata
      ])

  defp storage_attrs(manifest, expires_at) do
    %{
      filename: manifest.filename,
      content_type: manifest.mime,
      size: manifest.size,
      checksum: manifest.sha256,
      expires_at: expires_at
    }
  end

  defp validate_encoded_ceiling(artifact_id, encoded) when is_binary(encoded) do
    response = JSON.encode!(%{"artifact_id" => artifact_id, "content" => encoded})

    if byte_size(response) <= @inline_response_limit,
      do: :ok,
      else: {:error, :inline_artifact_too_large}
  end

  defp validate_encoded_ceiling(_artifact_id, _encoded), do: {:error, :invalid_inline_content}

  defp decode_content(encoded) do
    case Base.decode64(encoded) do
      {:ok, content} -> {:ok, content}
      :error -> {:error, :invalid_inline_content}
    end
  end

  defp upload_base_url(opts) do
    configured =
      case Application.get_env(:gsmlg_browser, :upload_base_url) do
        value when is_binary(value) and value != "" -> value
        _unset -> nil
      end

    value = Keyword.get(opts, :upload_base_url, configured)

    if configured && value != configured do
      {:error, :invalid_upload_origin}
    else
      case URI.parse(value || "") do
        %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri
        when is_binary(host) and host != "" ->
          case uri.path do
            path when path in [nil, "", "/"] ->
              {:ok, URI.to_string(%{uri | path: "/browser-artifact-uploads"})}

            "/browser-artifact-uploads" ->
              {:ok, URI.to_string(uri)}

            _other ->
              {:error, :invalid_upload_origin}
          end

        _invalid ->
          {:error, :invalid_upload_origin}
      end
    end
  end

  defp upload_url(base, artifact_id), do: String.trim_trailing(base, "/") <> "/#{artifact_id}"

  defp expected_headers(artifact, token) do
    %{
      "content-type" => artifact.mime,
      "content-length" => Integer.to_string(artifact.size),
      "x-content-sha256" => artifact.sha256,
      "x-browser-upload-token" => token
    }
  end

  defp validate_headers(artifact, token, headers) when is_map(headers) do
    normalized = Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)

    if normalized == expected_headers(artifact, token),
      do: :ok,
      else: {:error, :upload_headers_mismatch}
  end

  defp validate_headers(_artifact, _token, _headers), do: {:error, :upload_headers_mismatch}

  defp validate_token(artifact, token) when is_binary(token) do
    actual = token_digest(token)
    expected = artifact.upload_token_digest

    if is_binary(expected) and byte_size(actual) == byte_size(expected) and
         Plug.Crypto.secure_compare(actual, expected),
       do: :ok,
       else: {:error, :invalid_upload_token}
  end

  defp validate_token(_artifact, _token), do: {:error, :invalid_upload_token}

  defp validate_not_expired(%Artifact{upload_expires_at: expires_at}) do
    if match?(%DateTime{}, expires_at) and DateTime.after?(expires_at, DateTime.utc_now()),
      do: :ok,
      else: {:error, :upload_expired}
  end

  defp finish_ack(owner, artifact, opts) do
    result =
      case Keyword.fetch(opts, :ack) do
        {:ok, ack} -> ack.(owner, artifact)
        :error -> remote_ack(owner, artifact)
      end

    attrs =
      case result do
        :ok -> %{ack_status: "acked", acked_at: DateTime.utc_now()}
        {:ok, _response} -> %{ack_status: "acked", acked_at: DateTime.utc_now()}
        _failure -> %{ack_status: "pending", ack_attempts: artifact.ack_attempts + 1}
      end

    case persist_ack_state(artifact, attrs) do
      {:ok, updated} ->
        :ok = Notifier.resource_changed(:artifact, updated.id, :verified)
        :ok = notify_owner(updated)

        case updated.ack_status do
          "acked" ->
            case finalize_owner(updated) do
              :ok ->
                {:ok, updated}

              {:error, _reason} = error ->
                _ = enqueue_ack_retry(updated)
                error
            end

          _pending ->
            {:ok, updated}
        end

      {:error, _changeset} ->
        {:error, :artifact_ack_state_failed}
    end
  end

  defp persist_ack_state(artifact, attrs) do
    Repo.transaction(fn ->
      with {:ok, updated} <-
             artifact |> Artifact.verification_changeset(attrs) |> Repo.update(),
           :ok <- maybe_enqueue_ack_retry(updated) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp maybe_enqueue_ack_retry(%Artifact{ack_status: "pending"} = artifact),
    do: enqueue_ack_retry(artifact)

  defp maybe_enqueue_ack_retry(%Artifact{}), do: :ok

  defp enqueue_ack_retry(artifact) do
    case Oban.insert(ArtifactAckWorker.new(%{"artifact_id" => artifact.id})) do
      {:ok, _oban_job} -> :ok
      {:error, _changeset} -> {:error, :artifact_ack_enqueue_failed}
    end
  end

  defp artifact_owner(%Artifact{job_id: job_id, session_id: nil}) when is_binary(job_id),
    do: Repo.get(Job, job_id)

  defp artifact_owner(%Artifact{job_id: nil, session_id: session_id}) when is_binary(session_id),
    do: Repo.get(Session, session_id)

  defp artifact_owner(_artifact), do: nil

  defp notify_owner(%Artifact{job_id: job_id, session_id: nil}) when is_binary(job_id),
    do: Notifier.job_changed(job_id, :artifact)

  defp notify_owner(%Artifact{job_id: nil, session_id: session_id}) when is_binary(session_id),
    do: Notifier.resource_changed(:session, session_id, :artifact)

  defp finalize_owner(%Artifact{job_id: job_id, session_id: nil}) when is_binary(job_id) do
    case GSMLG.Browser.finalize_job_artifacts(job_id) do
      {:ok, _job} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp finalize_owner(%Artifact{job_id: nil, session_id: session_id})
       when is_binary(session_id),
       do: :ok

  defp remote_ack(owner, artifact) do
    node = Repo.get!(Node, owner.node_id)
    CommanderBridge.artifact_ack(owner, node, artifact)
  end

  defp token_digest(token), do: :crypto.hash(:sha256, token)

  defp max_artifact_bytes,
    do: Application.get_env(:gsmlg_browser, :max_artifact_bytes, 104_857_600)

  defp upload_ttl_seconds(opts) do
    ttl =
      Keyword.get(
        opts,
        :upload_ttl_seconds,
        Application.get_env(:gsmlg_browser, :upload_ttl_seconds, 300)
      )

    if is_integer(ttl) and ttl in 1..900, do: {:ok, ttl}, else: {:error, :invalid_upload_expiry}
  end

  defp rpc_timeout_ms, do: Application.get_env(:gsmlg_browser, :rpc_timeout_ms, 30_000)
end
