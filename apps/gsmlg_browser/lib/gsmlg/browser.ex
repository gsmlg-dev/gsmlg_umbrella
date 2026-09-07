defmodule GSMLG.Browser do
  @moduledoc "PostgreSQL-authoritative facade for remote browser control."

  import Ecto.Query

  alias Ecto.Multi

  alias GSMLG.Browser.{
    Artifact,
    ChatURL,
    CommanderBridge,
    Error,
    Enabled,
    Job,
    JobEvent,
    JobState,
    Node,
    Notifier,
    Origin,
    Profile,
    Session,
    SessionProxy,
    Telemetry,
    WorkflowContract
  }

  alias GSMLG.Browser.Workers.DispatchWorker
  alias GSMLG.Browser.Workers.ArtifactTransferWorker
  alias GSMLG.CommandPlatform.AgentRegistry
  alias GSMLG.CommandPlatform.RPCDispatcher
  alias GSMLG.Commander.Protocol.{ArtifactManifest, RPCAccepted, RPCError, TLSSummary}
  alias GSMLG.Repo

  @type result(value) :: {:ok, value} | {:error, Error.t()}
  @live_node_limit 100
  @manager_status_timeout_ms 5_000
  @manager_status_task_timeout_ms 5_500
  @tls_metadata_keys ~w(tls_status tls_expires_at tls_remaining_seconds)
  @max_tls_remaining_seconds 4_294_967_295

  @spec list_nodes(map(), keyword()) :: result([Node.t()])
  def list_nodes(actor, opts) do
    with {:ok, _actor_id} <- actor_id(actor),
         :ok <- validate_id_cursor(Keyword.get(opts, :after)) do
      registry = Keyword.get(opts, :agent_registry, AgentRegistry)
      live = live_browser_agents(registry)

      with :ok <- synchronize_live_nodes(live, opts) do
        query =
          from(node in Node,
            order_by: [asc: node.id],
            limit: ^bounded_limit(opts)
          )

        query = after_id(query, Keyword.get(opts, :after))

        nodes =
          Repo.all(query)
          |> Enum.map(&merge_live_node(&1, live))

        {:ok, nodes}
      end
    end
  end

  @spec get_node(map(), Ecto.UUID.t()) :: result(Node.t())
  def get_node(actor, id) do
    with {:ok, _actor_id} <- actor_id(actor),
         :ok <- validate_uuid(id),
         %Node{} = node <- Repo.get(Node, id) do
      {:ok, merge_live_node(node, live_browser_agents(AgentRegistry))}
    else
      nil -> error(:not_found)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec list_profiles(map(), Ecto.UUID.t(), keyword()) :: result([Profile.t()])
  def list_profiles(actor, node_id, opts) do
    with {:ok, %Node{}} <- get_node(actor, node_id),
         :ok <- validate_id_cursor(Keyword.get(opts, :after)) do
      query =
        from(profile in Profile,
          where: profile.node_id == ^node_id,
          order_by: [asc: profile.id],
          limit: ^bounded_limit(opts)
        )

      query =
        case Keyword.get(opts, :after) do
          cursor when is_binary(cursor) -> from(profile in query, where: profile.id > ^cursor)
          _none -> query
        end

      {:ok, Repo.all(query)}
    end
  end

  @spec sync_profiles(map(), Ecto.UUID.t()) :: result([Profile.t()])
  def sync_profiles(actor, node_id) do
    with {:ok, %Node{} = node} <- get_node(actor, node_id),
         {:ok, profiles} when is_list(profiles) <-
           CommanderBridge.call(
             node,
             "profiles.list",
             %{},
             "profiles.sync:#{node.id}:#{System.system_time(:second)}",
             DateTime.add(DateTime.utc_now(), 30, :second)
           ),
         {:ok, synced} <- persist_profiles(node, profiles) do
      {:ok, synced}
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
      _invalid -> error(:invalid_rpc_response)
    end
  end

  @spec launch_profile(map(), Ecto.UUID.t()) :: result(Profile.t())
  def launch_profile(actor, profile_id),
    do: mutate_profile(actor, profile_id, "profile.launch", "running")

  @spec stop_profile(map(), Ecto.UUID.t()) :: result(Profile.t())
  def stop_profile(actor, profile_id),
    do: mutate_profile(actor, profile_id, "profile.stop", "stopped")

  @spec configure_profile(map(), Ecto.UUID.t(), map()) :: result(Profile.t())
  def configure_profile(actor, profile_id, attrs) when is_map(attrs) do
    with {:ok, _actor_id} <- actor_id(actor),
         :ok <- validate_uuid(profile_id),
         {:ok, params} <- normalize_profile_configuration(attrs) do
      result =
        Repo.transaction(fn ->
          with %Profile{} = profile <- Repo.get(Profile, profile_id),
               %Node{} <-
                 Repo.one(
                   from(node in Node, where: node.id == ^profile.node_id, lock: "FOR UPDATE")
                 ),
               %Profile{} = locked <-
                 Repo.one(
                   from(item in Profile, where: item.id == ^profile.id, lock: "FOR UPDATE")
                 ),
               :ok <- configurable_profile(locked, params),
               :ok <- select_profile_default(locked, params.is_default),
               {:ok, updated} <-
                 locked
                 |> Profile.changeset(%{
                   enabled: params.enabled,
                   is_default: params.is_default,
                   automation_status: configured_automation_status(locked, params.enabled),
                   policy: %{"allowed_origins" => params.allowed_origins}
                 })
                 |> Repo.update() do
            updated
          else
            nil -> Repo.rollback(:not_found)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, %Profile{} = profile} ->
          :ok = Notifier.resource_changed(:profile, profile.id, :configured)
          {:ok, profile}

        {:error, reason} ->
          error(reason)
      end
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  rescue
    Ecto.ConstraintError -> error(:conflict)
  end

  def configure_profile(_actor, _profile_id, _attrs), do: error(:invalid_request)

  @spec create_session(map(), map()) :: result(Session.t())
  def create_session(actor, attrs) when is_map(attrs) do
    with {:ok, actor_id} <- actor_id(actor),
         {:ok, params} <- normalize_session_attrs(attrs),
         params <- bind_session_operator(params, actor_id),
         %Profile{} = profile <- Repo.get(Profile, params.profile_id),
         :ok <- validate_session_profile(profile, params.node_id),
         %Node{enabled: true} = node <- Repo.get(Node, params.node_id),
         {:ok, session} <- insert_opening_session(actor_id, node, profile, params) do
      complete_session_open(session, node, profile, params)
    else
      nil -> error(:not_found)
      %Node{} -> error(:node_disabled)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  def create_session(_actor, _attrs), do: error(:invalid_request)

  @spec get_session(map(), Ecto.UUID.t()) :: result(Session.t())
  def get_session(actor, session_id) do
    with {:ok, actor_id} <- actor_id(actor),
         :ok <- validate_uuid(session_id),
         %Session{} = session <- Repo.get_by(Session, id: session_id, owner_actor_id: actor_id) do
      {:ok, session}
    else
      nil -> error(:not_found)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec list_sessions(map(), keyword()) :: result([Session.t()])
  def list_sessions(actor, opts) do
    with {:ok, actor_id} <- actor_id(actor),
         :ok <- validate_id_cursor(Keyword.get(opts, :after)) do
      query =
        from(session in Session,
          where: session.owner_actor_id == ^actor_id,
          order_by: [asc: session.id],
          limit: ^bounded_limit(opts)
        )

      {:ok, query |> after_id(Keyword.get(opts, :after)) |> Repo.all()}
    end
  end

  @spec observe_session(map(), Ecto.UUID.t()) :: result(map())
  def observe_session(actor, session_id) do
    with {:ok, %Session{mode: "automation", status: status} = session} <-
           get_session(actor, session_id),
         true <- status in ~w(ready waiting waiting_human),
         {:ok, result} <-
           SessionProxy.call(
             session,
             "session.observe",
             %{"session_id" => session.remote_session_id},
             "session.observe:#{session.id}:#{session.revision}"
           ),
         :ok <- validate_session_identity(session, result),
         {:ok, updated} <- update_session_revision(session, result) do
      :ok = Notifier.resource_changed(:session, updated.id, :observed)
      {:ok, %{session: updated, observation: result}}
    else
      {:ok, %Session{}} -> error(:invalid_session_state)
      false -> error(:invalid_session_state)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec execute_action(map(), Ecto.UUID.t(), map()) :: result(map())
  def execute_action(actor, session_id, action) do
    with {:ok, %Session{status: "ready"} = session} <- get_session(actor, session_id),
         {:ok, remote_action} <- normalize_action(session, action) do
      execute_remote_action(session, remote_action)
    else
      {:ok, %Session{}} -> error(:invalid_session_state)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec manual_acquire(map(), Ecto.UUID.t()) :: result(Session.t())
  def manual_acquire(actor, session_id), do: manual_session_operation(actor, session_id, :acquire)

  @spec manual_release(map(), Ecto.UUID.t()) :: result(Session.t())
  def manual_release(actor, session_id), do: manual_session_operation(actor, session_id, :release)

  @spec close_session(map(), Ecto.UUID.t()) :: result(Session.t())
  def close_session(actor, session_id) do
    with {:ok, %Session{} = session} <- get_session(actor, session_id) do
      if session.status == "closed" do
        {:ok, session}
      else
        close_remote_session(session)
      end
    end
  end

  @spec create_job(map(), map()) :: result(Job.t())
  def create_job(actor, attrs) when is_map(attrs) do
    with {:ok, actor_id} <- actor_id(actor),
         {:ok, attrs} <- normalize_job_attrs(attrs, actor_id),
         {:ok, attrs} <- resolve_job_resources(attrs),
         :ok <- validate_job(attrs) do
      case Repo.get_by(Job,
             requested_by_actor_id: actor_id,
             idempotency_key: attrs.idempotency_key
           ) do
        %Job{} = existing -> replay_or_conflict(existing, attrs)
        nil -> create_job_transaction(attrs)
      end
    end
  end

  def create_job(_actor, _attrs), do: error(:invalid_request)

  @spec list_jobs(map(), keyword()) :: result([Job.t()])
  def list_jobs(actor, opts) do
    with {:ok, actor_id} <- actor_id(actor),
         :ok <- validate_id_cursor(Keyword.get(opts, :after)) do
      query =
        from(job in Job,
          where: job.requested_by_actor_id == ^actor_id,
          order_by: [asc: job.id],
          limit: ^bounded_limit(opts)
        )

      query = after_id(query, Keyword.get(opts, :after))

      {:ok, Repo.all(query)}
    end
  end

  @spec get_job(map(), Ecto.UUID.t()) :: result(Job.t())
  def get_job(actor, id) do
    with {:ok, actor_id} <- actor_id(actor),
         :ok <- validate_uuid(id),
         %Job{} = job <- Repo.get_by(Job, id: id, requested_by_actor_id: actor_id) do
      {:ok, job}
    else
      nil -> error(:not_found)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec list_job_events(map(), Ecto.UUID.t(), keyword()) :: result([JobEvent.t()])
  def list_job_events(actor, job_id, opts) do
    with {:ok, %Job{} = job} <- get_job(actor, job_id),
         :ok <- validate_sequence_cursor(Keyword.get(opts, :after_sequence)) do
      query =
        from(event in JobEvent,
          where: event.job_id == ^job.id,
          order_by: [asc: event.sequence],
          limit: ^bounded_limit(opts)
        )

      query =
        case Keyword.get(opts, :after_sequence) do
          sequence when is_integer(sequence) and sequence >= 0 ->
            from(event in query, where: event.sequence > ^sequence)

          _none ->
            query
        end

      {:ok, Repo.all(query)}
    end
  end

  @spec cancel_job(map(), Ecto.UUID.t()) :: result(Job.t())
  def cancel_job(actor, job_id) do
    with {:ok, %Job{} = job} <- get_job(actor, job_id) do
      if job.status == "cancelled", do: {:ok, job}, else: do_cancel_job(job)
    end
  end

  defp do_cancel_job(job) do
    if job.status == "queued" do
      cancel_queued_job(job)
    else
      with :ok <-
             controllable_job(
               job,
               ~w(accepted unknown running waiting_human collecting_artifacts)
             ),
           %Node{} = node <- Repo.get(Node, job.node_id) do
        finish_control(
          job,
          CommanderBridge.operation(
            job,
            node,
            "workflow.cancel",
            "#{job.idempotency_key}:cancel"
          ),
          "cancelled"
        )
      else
        {:error, reason} -> error(reason)
        nil -> error(:not_found)
      end
    end
  end

  @spec resume_job(map(), Ecto.UUID.t()) :: result(Job.t())
  def resume_job(actor, job_id) do
    with {:ok, actor_id} <- actor_id(actor),
         {:ok, %Job{status: "waiting_human"} = job} <- get_job(actor, job_id),
         {:ok, job} <- reacquire_profile(job),
         %Node{} = node <- Repo.get(Node, job.node_id) do
      finish_resume_control(
        job,
        CommanderBridge.operation(
          job,
          node,
          "workflow.resume",
          "#{job.idempotency_key}:resume",
          payload: %{"operator_id" => actor_id}
        )
      )
    else
      {:ok, %Job{}} -> error(:invalid_job_state)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
      nil -> error(:not_found)
    end
  end

  @spec retry_job(map(), Ecto.UUID.t(), String.t()) :: result(Job.t())
  def retry_job(actor, job_id, idempotency_key) do
    with {:ok, actor_id} <- actor_id(actor),
         true <- is_binary(idempotency_key) and byte_size(idempotency_key) in 1..512,
         {:ok, %Job{status: status} = parent} <- get_job(actor, job_id),
         true <- status in ["failed", "cancelled"],
         :ok <- validate_retry_attempt(parent) do
      create_retry_transaction(parent, %{
        node_id: parent.node_id,
        profile_id: parent.profile_id,
        session_id: parent.session_id,
        workflow: parent.workflow,
        workflow_version: parent.workflow_version,
        status: "queued",
        input: parent.input,
        output_formats: parent.output_formats,
        idempotency_key: idempotency_key,
        attempt: parent.attempt + 1,
        previous_job_id: parent.id,
        requested_by_actor_id: actor_id,
        deadline_at: default_deadline()
      })
    else
      false -> error(:invalid_request)
      {:ok, %Job{}} -> error(:invalid_job_state)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec list_artifacts(map(), Ecto.UUID.t()) :: result([Artifact.t()])
  def list_artifacts(actor, job_id), do: list_artifacts(actor, job_id, [])

  @spec list_artifacts(map(), Ecto.UUID.t(), keyword()) :: result([Artifact.t()])
  def list_artifacts(actor, job_id, opts) do
    with {:ok, %Job{} = job} <- get_job(actor, job_id),
         :ok <- validate_id_cursor(Keyword.get(opts, :after)) do
      query =
        from(artifact in Artifact,
          where: artifact.job_id == ^job.id,
          order_by: [asc: artifact.id],
          limit: ^bounded_limit(opts)
        )

      {:ok,
       query
       |> after_id(Keyword.get(opts, :after))
       |> Repo.all()}
    end
  end

  @spec get_artifact(map(), Ecto.UUID.t()) :: result(Artifact.t())
  def get_artifact(actor, artifact_id) do
    with {:ok, actor_id} <- actor_id(actor),
         :ok <- validate_uuid(artifact_id),
         %Artifact{} = artifact <-
           Repo.one(
             from(artifact in Artifact,
               left_join: job in Job,
               on: job.id == artifact.job_id,
               left_join: session in Session,
               on: session.id == artifact.session_id,
               where:
                 artifact.id == ^artifact_id and
                   (job.requested_by_actor_id == ^actor_id or
                      session.owner_actor_id == ^actor_id),
               select: artifact
             )
           ) do
      {:ok, artifact}
    else
      nil -> error(:not_found)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec open_artifact(map(), Ecto.UUID.t()) :: result(map())
  def open_artifact(actor, artifact_id) do
    with {:ok, %Artifact{status: "verified"} = artifact} <- get_artifact(actor, artifact_id),
         {:ok, source} <- artifact_source(artifact) do
      {:ok,
       %{
         artifact_id: artifact.id,
         content_type: artifact.mime,
         filename: artifact.filename,
         size: artifact.size,
         sha256: artifact.sha256,
         source: source
       }}
    else
      {:ok, %Artifact{}} -> error(:artifact_not_verified)
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  @spec read_artifact_range(map(), Ecto.UUID.t(), non_neg_integer(), non_neg_integer()) ::
          result(binary())
  def read_artifact_range(actor, artifact_id, first, last) do
    with {:ok, stream} <- open_artifact(actor, artifact_id),
         :ok <- validate_range(first, last, stream.size) do
      case stream.source do
        {:inline, content} ->
          {:ok, binary_part(content, first, last - first + 1)}

        {:storage, storage_id} ->
          storage_result(GSMLG.Storage.read_range(storage_id, first, last))
      end
    end
  end

  @spec subscribe(map(), :updates | {:job, Ecto.UUID.t()}) :: result(:subscribed)
  def subscribe(actor, :updates) do
    with {:ok, _actor_id} <- actor_id(actor),
         :ok <- Phoenix.PubSub.subscribe(GSMLG.PubSub, "browser:updates") do
      {:ok, :subscribed}
    end
  end

  def subscribe(actor, {:job, job_id}) do
    with {:ok, %Job{}} <- get_job(actor, job_id),
         :ok <- Phoenix.PubSub.subscribe(GSMLG.PubSub, "browser:job:#{job_id}") do
      {:ok, :subscribed}
    end
  end

  def subscribe(_actor, _topic), do: error(:invalid_request)

  @doc false
  def dispatch_job(job_id, opts \\ []) do
    result =
      case claim_dispatch(job_id) do
        {:ok, %Job{status: "dispatching"} = job, node, profile} ->
          complete_dispatch(job, node, profile, CommanderBridge.start(job, node, profile, opts))

        {:ok, %Job{} = job, nil, nil} ->
          {:ok, job}

        {:error, _reason} = error ->
          error
      end

    notify_job_result(result, :dispatch)
  end

  @doc false
  def reconcile_job_id(job_id, opts \\ []) do
    Telemetry.measure_reconcile(job_id, fn -> do_reconcile_job_id(job_id, opts) end)
  end

  defp do_reconcile_job_id(job_id, opts) do
    with %Job{} = job <- Repo.get(Job, job_id),
         %Node{} = node <- Repo.get(Node, job.node_id),
         :ok <- register_execution_owner(node, job.remote_execution_id),
         {:ok, result} <- CommanderBridge.reconcile(job, node, opts),
         {:ok, status} <- result_status(result),
         {:ok, chat_url} <- ChatURL.from_rpc(result, job.chat_url),
         {:ok, updated} <- persist_reconcile(job.id, node, result, status, chat_url),
         :ok <- register_execution_owner(node, updated.remote_execution_id),
         :ok <- Notifier.job_changed(updated.id, :reconcile) do
      {:ok, updated}
    else
      nil -> {:error, :not_found}
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} = error -> error
    end
  end

  defp register_execution_owner(_node, nil), do: :ok

  defp register_execution_owner(node, remote_execution_id),
    do: RPCDispatcher.register_execution_owner(node.commander_id, remote_execution_id)

  defp persist_reconcile(job_id, node, result, status, chat_url) do
    Repo.transaction(fn ->
      current = Repo.one(from(job in Job, where: job.id == ^job_id, lock: "FOR UPDATE"))

      with %Job{} = current <- current,
           :ok <- validate_reconcile_execution(current, result["remote_execution_id"]),
           {:ok, session_id} <- bind_reconciled_workflow_session(current, result, status),
           persisted_status <- persisted_reconcile_status(status),
           :ok <- JobState.validate(current.status, persisted_status),
           {:ok, updated} <-
             current
             |> Job.transition_changeset(%{
               session_id: session_id,
               remote_execution_id: result["remote_execution_id"],
               status: persisted_status,
               phase: result["phase"],
               chat_url: chat_url,
               result: safe_reconcile_result(result, status),
               error: safe_reconcile_error(result),
               completed_at: terminal_time(persisted_status)
             })
             |> Repo.update(),
           :ok <- register_reconciled_artifacts(node, updated, result),
           :ok <- enqueue_artifact_transfers(updated),
           {:ok, finalized} <- maybe_finalize_artifacts(updated),
           :ok <- maybe_release_job_profile(finalized) do
        finalized
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_reconcile_execution(%Job{remote_execution_id: nil}, remote_id)
       when is_binary(remote_id),
       do: :ok

  defp validate_reconcile_execution(%Job{remote_execution_id: remote_id}, remote_id), do: :ok
  defp validate_reconcile_execution(%Job{}, _remote_id), do: {:error, :execution_mismatch}

  defp bind_reconciled_workflow_session(job, result, status) when is_map(result) do
    case Map.get(result, "remote_session_id") do
      nil ->
        {:ok, job.session_id}

      remote_id when is_binary(remote_id) ->
        do_bind_reconciled_session(job, remote_id, result["remote_execution_id"], status)

      _invalid ->
        {:error, :invalid_rpc_response}
    end
  end

  defp bind_reconciled_workflow_session(_job, _result, _status),
    do: {:error, :invalid_rpc_response}

  defp do_bind_reconciled_session(job, remote_id, central_session_id, status) do
    with {:ok, _uuid} <- Ecto.UUID.cast(remote_id),
         {:ok, _uuid} <- Ecto.UUID.cast(central_session_id),
         %Profile{} = profile <- lock_reconciled_profile(job.profile_id),
         {:ok, profile} <- persist_workflow_profile_authority(profile, status) do
      case {job.session_id, locked_reconciled_session(job, central_session_id, remote_id)} do
        {_session_id, %Session{} = session} ->
          validate_reconciled_session_owner(
            session,
            job,
            central_session_id,
            remote_id
          )

        {nil, nil} ->
          insert_reconciled_session(job, profile, central_session_id, remote_id, status)

        {_session_id, nil} ->
          {:error, :session_mismatch}
      end
    else
      :error -> {:error, :invalid_rpc_response}
      nil -> {:error, :profile_not_found}
    end
  end

  defp lock_reconciled_profile(profile_id) do
    Repo.one(from(profile in Profile, where: profile.id == ^profile_id, lock: "FOR UPDATE"))
  end

  defp persist_workflow_profile_authority(profile, status)
       when status in ["running", "waiting_human"] do
    target = if status == "waiting_human", do: "manual", else: "leased"

    case profile do
      %Profile{automation_status: ^target} ->
        {:ok, profile}

      %Profile{automation_status: current} when current in ["leased", "manual"] ->
        profile |> Profile.changeset(%{automation_status: target}) |> Repo.update()

      %Profile{} ->
        {:error, :profile_authority_conflict}
    end
  end

  defp persist_workflow_profile_authority(profile, _status), do: {:ok, profile}

  defp locked_reconciled_session(%Job{session_id: session_id}, central_session_id, remote_id)
       when is_binary(session_id) do
    Repo.one(
      from(session in Session,
        where:
          session.id == ^session_id and session.id == ^central_session_id and
            session.remote_session_id == ^remote_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp locked_reconciled_session(%Job{session_id: nil}, central_session_id, remote_id) do
    Repo.one(
      from(session in Session,
        where: session.id == ^central_session_id or session.remote_session_id == ^remote_id,
        lock: "FOR UPDATE"
      )
    )
  end

  defp validate_reconciled_session_owner(session, job, central_session_id, remote_id) do
    if session.id == central_session_id and session.remote_session_id == remote_id and
         session.node_id == job.node_id and
         session.profile_id == job.profile_id and
         session.owner_actor_id == job.requested_by_actor_id do
      {:ok, session.id}
    else
      {:error, :session_mismatch}
    end
  end

  defp insert_reconciled_session(job, profile, central_session_id, remote_id, status) do
    attrs = %{
      node_id: job.node_id,
      profile_id: job.profile_id,
      remote_session_id: remote_id,
      mode: reconciled_session_mode(status),
      status: reconciled_session_status(status),
      origin_policy: %{
        "authorized_origins" => Map.get(profile.policy || %{}, "allowed_origins", [])
      },
      revision: 0,
      owner_actor_id: job.requested_by_actor_id,
      last_seen_at: DateTime.utc_now(),
      expires_at: job.deadline_at
    }

    case %Session{id: central_session_id} |> Session.changeset(attrs) |> Repo.insert() do
      {:ok, session} -> {:ok, session.id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconciled_session_mode("waiting_human"), do: "manual"
  defp reconciled_session_mode(_status), do: "automation"

  defp reconciled_session_status("waiting_human"), do: "waiting_human"
  defp reconciled_session_status("cancelled"), do: "closed"
  defp reconciled_session_status("failed"), do: "failed"
  defp reconciled_session_status(_status), do: "ready"

  defp persisted_reconcile_status("completed"), do: "collecting_artifacts"
  defp persisted_reconcile_status(status), do: status

  defp register_reconciled_artifacts(node, job, result) do
    case Map.get(result, "artifacts", []) do
      artifacts when is_list(artifacts) and length(artifacts) <= 16 ->
        Enum.reduce_while(artifacts, :ok, fn wire, :ok ->
          with true <- is_map(wire),
               {:ok, manifest} <-
                 ArtifactManifest.decode(Map.put(wire, "type", "artifact.manifest")),
               true <- manifest.job_id == job.id,
               true <- manifest.metadata["remote_execution_id"] == job.remote_execution_id,
               {:ok, _artifact} <-
                 GSMLG.Browser.ArtifactService.register_pending(node.commander_id, manifest) do
            {:cont, :ok}
          else
            _invalid -> {:halt, {:error, :invalid_artifact_manifest}}
          end
        end)

      _invalid ->
        {:error, :invalid_artifact_manifest}
    end
  end

  defp safe_reconcile_result(result, remote_status) do
    safe = %{
      "last_sequence" => bounded_nonnegative(result["last_sequence"]),
      "artifact_count" => bounded_list_length(result["artifacts"]),
      "pending_artifact_count" =>
        bounded_nonnegative(get_in(result, ["outbox", "pending_artifact_count"]))
    }

    if remote_status == "completed", do: Map.put(safe, "remote_completed", true), else: safe
  end

  defp enqueue_artifact_transfers(job) do
    Repo.all(
      from(artifact in Artifact,
        where:
          artifact.job_id == ^job.id and artifact.status == "pending" and
            artifact.transfer_mode == "remote_pending",
        order_by: [asc: artifact.id],
        limit: 16,
        select: artifact.id
      )
    )
    |> Enum.reduce_while(:ok, fn artifact_id, :ok ->
      case Oban.insert(ArtifactTransferWorker.new(%{"artifact_id" => artifact_id})) do
        {:ok, _oban_job} -> {:cont, :ok}
        {:error, _changeset} -> {:halt, {:error, :artifact_transfer_enqueue_failed}}
      end
    end)
  end

  defp maybe_finalize_artifacts(%Job{} = job) do
    if artifacts_complete?(job) do
      with :ok <- JobState.validate(job.status, "completed") do
        job
        |> Job.transition_changeset(%{status: "completed", completed_at: DateTime.utc_now()})
        |> Repo.update()
      end
    else
      {:ok, job}
    end
  end

  defp artifacts_complete?(%Job{result: %{"remote_completed" => true}} = job) do
    artifacts = Repo.all(from(artifact in Artifact, where: artifact.job_id == ^job.id))
    expected = MapSet.new(job.output_formats)
    present = MapSet.new(artifacts, & &1.kind)
    remote_last_sequence = Map.get(job.result, "last_sequence", 0)

    job.status == "collecting_artifacts" and job.last_remote_sequence >= remote_last_sequence and
      MapSet.subset?(expected, present) and artifacts != [] and
      Enum.all?(artifacts, &(&1.status == "verified" and &1.ack_status == "acked"))
  end

  defp artifacts_complete?(_job), do: false

  @doc false
  def finalize_job_artifacts(job_id) do
    with :ok <- Enabled.ensure() do
      result =
        Repo.transaction(fn ->
          current = Repo.one(from(job in Job, where: job.id == ^job_id, lock: "FOR UPDATE"))

          with %Job{} = current <- current,
               {:ok, finalized} <- maybe_finalize_artifacts(current),
               :ok <- maybe_release_job_profile(finalized) do
            finalized
          else
            nil -> Repo.rollback(:not_found)
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      case result do
        {:ok, %Job{} = job} ->
          :ok = Notifier.job_changed(job.id, :artifact)
          {:ok, job}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp safe_reconcile_error(%{"intervention" => intervention}) when is_map(intervention) do
    case intervention["reason_code"] || intervention["reason"] do
      code when is_binary(code) and byte_size(code) <= 128 -> %{"code" => code}
      _none -> nil
    end
  end

  defp safe_reconcile_error(_result), do: nil

  defp bounded_nonnegative(value) when is_integer(value) and value >= 0,
    do: min(value, 1_000_000_000)

  defp bounded_nonnegative(_value), do: 0
  defp bounded_list_length(value) when is_list(value), do: min(length(value), 16)
  defp bounded_list_length(_value), do: 0

  defp maybe_release_job_profile(%Job{status: status, session_id: nil, profile_id: profile_id})
       when status in ~w(completed failed cancelled) do
    case release_profile(profile_id) do
      {:ok, _profile} -> :ok
      :ok -> :ok
      {:error, _reason} -> {:error, :profile_release_failed}
    end
  end

  defp maybe_release_job_profile(_job), do: :ok

  @spec reconcile_job(map(), Ecto.UUID.t()) :: result(Job.t())
  def reconcile_job(actor, job_id) do
    with {:ok, %Job{} = job} <- get_job(actor, job_id) do
      public_result(reconcile_job_id(job.id))
    end
  end

  defp create_job_transaction(attrs) do
    Multi.new()
    |> Multi.run(:profile, fn repo, _changes ->
      query = from(profile in Profile, where: profile.id == ^attrs.profile_id, lock: "FOR UPDATE")

      case repo.one(query) do
        %Profile{node_id: node_id} when node_id != attrs.node_id ->
          {:error, :profile_node_mismatch}

        %Profile{enabled: false} ->
          {:error, :profile_disabled}

        %Profile{automation_status: status} when status != "available" ->
          {:error, :profile_busy}

        %Profile{} = profile ->
          {:ok, profile}

        nil ->
          {:error, :profile_not_found}
      end
    end)
    |> Multi.run(:node, fn repo, _changes ->
      case repo.get(Node, attrs.node_id) do
        %Node{enabled: true} = node ->
          if browser_node_online?(node), do: {:ok, node}, else: {:error, :node_offline}

        %Node{} ->
          {:error, :node_disabled}

        nil ->
          {:error, :node_not_found}
      end
    end)
    |> Multi.insert(:job, Job.create_changeset(%Job{}, attrs))
    |> Multi.update(:lease_profile, fn %{profile: profile} ->
      Profile.changeset(profile, %{automation_status: "leased"})
    end)
    |> Multi.insert(:dispatch, fn %{job: job} ->
      DispatchWorker.new(%{"job_id" => job.id})
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{job: job}} ->
        :ok = Notifier.job_changed(job.id, :created)
        {:ok, job}

      {:error, _operation, reason, _changes} ->
        error(reason)
    end
  rescue
    Ecto.ConstraintError -> error(:conflict)
  end

  defp create_retry_transaction(parent, attrs) do
    case Repo.get_by(Job,
           requested_by_actor_id: attrs.requested_by_actor_id,
           idempotency_key: attrs.idempotency_key
         ) do
      %Job{previous_job_id: previous_job_id} = existing when previous_job_id == parent.id ->
        if retry_matches?(existing, parent),
          do: {:ok, existing},
          else: error(:idempotency_conflict)

      %Job{} ->
        error(:idempotency_conflict)

      nil ->
        Multi.new()
        |> Multi.run(:parent, fn repo, _changes ->
          case repo.one(from(job in Job, where: job.id == ^parent.id, lock: "FOR UPDATE")) do
            %Job{status: status} = locked when status in ["failed", "cancelled"] -> {:ok, locked}
            _other -> {:error, :invalid_job_state}
          end
        end)
        |> Multi.run(:profile, fn repo, _changes ->
          case repo.one(
                 from(profile in Profile,
                   where: profile.id == ^parent.profile_id,
                   lock: "FOR UPDATE"
                 )
               ) do
            %Profile{automation_status: "available"} = profile -> {:ok, profile}
            %Profile{} -> {:error, :profile_busy}
            nil -> {:error, :profile_not_found}
          end
        end)
        |> Multi.insert(:job, Job.create_changeset(%Job{}, attrs))
        |> Multi.update(:lease_profile, fn %{profile: profile} ->
          Profile.changeset(profile, %{automation_status: "leased"})
        end)
        |> Multi.insert(:dispatch, fn %{job: job} -> DispatchWorker.new(%{"job_id" => job.id}) end)
        |> Repo.transaction()
        |> case do
          {:ok, %{job: job}} ->
            :ok = Notifier.job_changed(job.id, :retried)
            {:ok, job}

          {:error, _operation, reason, _changes} ->
            error(reason)
        end
    end
  rescue
    Ecto.ConstraintError -> error(:conflict)
  end

  defp claim_dispatch(job_id) do
    Repo.transaction(fn ->
      query = from(job in Job, where: job.id == ^job_id, lock: "FOR UPDATE")

      case Repo.one(query) do
        nil ->
          Repo.rollback(:not_found)

        %Job{status: "queued"} = job ->
          {:ok, claimed} =
            job |> Job.transition_changeset(%{status: "dispatching"}) |> Repo.update()

          {claimed, Repo.get!(Node, job.node_id), Repo.get!(Profile, job.profile_id)}

        %Job{} = job ->
          {job, nil, nil}
      end
    end)
    |> case do
      {:ok, {%Job{} = job, node, profile}} -> {:ok, job, node, profile}
      {:error, reason} -> {:error, reason}
    end
  end

  defp complete_dispatch(job, _node, _profile, {:ok, %RPCAccepted{} = accepted}) do
    transition_job(job, %{
      status: "accepted",
      remote_execution_id: accepted.remote_execution_id,
      started_at: DateTime.utc_now(),
      error: nil
    })
  end

  defp complete_dispatch(job, _node, _profile, {:error, :rpc_timeout}) do
    transition_job(job, %{status: "unknown", error: %{"code" => "dispatch_timeout"}})
  end

  defp complete_dispatch(job, _node, profile, {:error, reason}) do
    Repo.transaction(fn ->
      with :ok <- JobState.validate(job.status, "failed"),
           {:ok, failed} <-
             job
             |> Job.transition_changeset(%{
               status: "failed",
               error: %{"code" => stable_reason(reason)},
               completed_at: DateTime.utc_now()
             })
             |> Repo.update(),
           {:ok, _profile} <-
             profile |> Profile.changeset(%{automation_status: "available"}) |> Repo.update() do
        failed
      else
        {:error, failed_reason} -> Repo.rollback(failed_reason)
      end
    end)
  end

  defp transition_job(job, attrs) do
    with :ok <- JobState.validate(job.status, attrs.status),
         {:ok, updated} <- job |> Job.transition_changeset(attrs) |> Repo.update() do
      {:ok, updated}
    end
  end

  defp normalize_job_attrs(attrs, actor_id) do
    attrs = for {key, value} <- attrs, into: %{}, do: {normalize_key(key), value}

    required = ~w(workflow workflow_version input output_formats idempotency_key)a

    optional = ~w(node_id profile_id session_id)a

    expected = required ++ Enum.filter(optional, &Map.has_key?(attrs, &1))

    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected) do
      {:ok,
       attrs
       |> Map.take(expected)
       |> Map.put(:requested_by_actor_id, actor_id)
       |> Map.put(:status, "queued")
       |> Map.put(:attempt, 1)
       |> Map.put(:deadline_at, default_deadline())}
    else
      error(:invalid_request)
    end
  end

  defp resolve_job_resources(%{requested_by_actor_id: actor_id} = attrs) do
    with {:ok, session} <- resolve_job_session(Map.get(attrs, :session_id), actor_id),
         {:ok, profile} <-
           resolve_job_profile(Map.get(attrs, :profile_id), session, Map.get(attrs, :node_id)),
         {:ok, node} <- resolve_job_node(Map.get(attrs, :node_id), profile, session),
         :ok <- validate_resource_identity(attrs, node, profile, session) do
      {:ok, attrs |> Map.put(:node_id, node.id) |> Map.put(:profile_id, profile.id)}
    end
  end

  defp resolve_job_session(nil, _actor_id), do: {:ok, nil}

  defp resolve_job_session(session_id, actor_id) do
    case Repo.get_by(Session, id: session_id, owner_actor_id: actor_id) do
      %Session{status: status} = session when status in ~w(ready waiting waiting_human) ->
        {:ok, session}

      %Session{} ->
        {:error, :invalid_session_state}

      nil ->
        {:error, :not_found}
    end
  end

  defp resolve_job_profile(nil, %Session{} = session, _node_id) do
    case Repo.get(Profile, session.profile_id) do
      %Profile{enabled: true} = profile -> {:ok, profile}
      %Profile{} -> {:error, :profile_disabled}
      nil -> {:error, :profile_not_found}
    end
  end

  defp resolve_job_profile(profile_id, _session, _node_id) when is_binary(profile_id) do
    case Repo.get(Profile, profile_id) do
      %Profile{enabled: true} = profile -> {:ok, profile}
      %Profile{} -> {:error, :profile_disabled}
      nil -> {:error, :profile_not_found}
    end
  end

  defp resolve_job_profile(nil, nil, node_id) do
    with {:ok, node} <- configured_job_node(node_id) do
      resolve_default_profile(node)
    end
  end

  defp resolve_job_profile(_profile_id, _session, _node_id), do: {:error, :invalid_request}

  defp resolve_job_node(nil, %Profile{} = profile, _session) do
    case Repo.get(Node, profile.node_id) do
      %Node{enabled: true} = node -> {:ok, node}
      %Node{} -> {:error, :node_disabled}
      nil -> {:error, :node_not_found}
    end
  end

  defp resolve_job_node(node_id, _profile, _session) when is_binary(node_id),
    do: configured_job_node(node_id)

  defp resolve_job_node(_node_id, _profile, _session), do: {:error, :invalid_request}

  defp configured_job_node(nil) do
    case Application.get_env(:gsmlg_browser, :default_node) do
      commander_id when is_binary(commander_id) and commander_id != "" ->
        case Repo.get_by(Node, commander_id: commander_id) do
          %Node{enabled: true} = node -> {:ok, node}
          %Node{} -> {:error, :node_disabled}
          nil -> {:error, :node_not_found}
        end

      _missing ->
        {:error, :node_not_found}
    end
  end

  defp configured_job_node(node_id) do
    case Repo.get(Node, node_id) do
      %Node{enabled: true} = node -> {:ok, node}
      %Node{} -> {:error, :node_disabled}
      nil -> {:error, :node_not_found}
    end
  end

  defp resolve_default_profile(node) do
    case Repo.one(
           from(profile in Profile,
             where: profile.node_id == ^node.id and profile.is_default and profile.enabled,
             limit: 1
           )
         ) do
      %Profile{} = profile -> {:ok, profile}
      nil -> {:error, :profile_not_found}
    end
  end

  defp validate_resource_identity(attrs, node, profile, session) do
    cond do
      profile.node_id != node.id ->
        {:error, :profile_node_mismatch}

      not is_nil(session) and session.node_id != node.id ->
        {:error, :session_mismatch}

      not is_nil(session) and session.profile_id != profile.id ->
        {:error, :session_mismatch}

      Map.has_key?(attrs, :profile_id) and attrs.profile_id != profile.id ->
        {:error, :profile_node_mismatch}

      true ->
        :ok
    end
  end

  defp validate_job(attrs) do
    with true <- match?({:ok, _}, Ecto.UUID.cast(attrs.node_id)),
         true <- match?({:ok, _}, Ecto.UUID.cast(attrs.profile_id)),
         true <- is_binary(attrs.idempotency_key) and byte_size(attrs.idempotency_key) in 1..512,
         :ok <-
           WorkflowContract.validate(
             attrs.workflow,
             attrs.workflow_version,
             attrs.input,
             attrs.output_formats
           ) do
      :ok
    else
      {:error, reason} -> error(reason)
      _invalid -> error(:invalid_request)
    end
  end

  defp replay_or_conflict(existing, attrs) do
    if job_fingerprint(existing) == job_fingerprint(attrs),
      do: {:ok, existing},
      else: error(:idempotency_conflict)
  end

  defp job_fingerprint(job) do
    for key <- [
          :node_id,
          :profile_id,
          :workflow,
          :workflow_version,
          :input,
          :output_formats,
          :session_id
        ],
        into: %{},
        do: {key, Map.get(job, key)}
  end

  defp retry_matches?(child, parent) do
    child.attempt == parent.attempt + 1 and
      child.requested_by_actor_id == parent.requested_by_actor_id and
      child.node_id == parent.node_id and child.profile_id == parent.profile_id and
      child.session_id == parent.session_id and child.workflow == parent.workflow and
      child.workflow_version == parent.workflow_version and child.input == parent.input and
      child.output_formats == parent.output_formats
  end

  defp controllable_job(%Job{status: "cancelled"}, _allowed), do: {:error, :already_cancelled}
  defp controllable_job(%Job{remote_execution_id: nil}, _allowed), do: {:error, :job_not_bound}

  defp controllable_job(%Job{status: status}, allowed) do
    if status in allowed, do: :ok, else: {:error, :invalid_job_state}
  end

  defp finish_control(job, {:ok, result}, expected_status) do
    case result_status(result) do
      {:ok, ^expected_status} ->
        public_result(transition_control_job(job, %{status: expected_status, error: nil}))

      {:ok, status} ->
        public_result(transition_control_job(job, %{status: status, phase: result["phase"]}))

      {:error, reason} ->
        error(reason)
    end
  end

  defp finish_control(job, {:error, :rpc_timeout}, _expected_status) do
    public_result(
      transition_control_job(job, %{
        status: "unknown",
        error: %{"code" => "control_timeout"}
      })
    )
  end

  defp finish_control(_job, {:error, reason}, _expected_status), do: error(reason)

  defp finish_resume_control(job, {:ok, result}) do
    case result_status(result) do
      {:ok, "running"} ->
        result =
          Repo.transaction(fn ->
            current = Repo.one(from(item in Job, where: item.id == ^job.id, lock: "FOR UPDATE"))

            profile =
              Repo.one(
                from(item in Profile, where: item.id == ^job.profile_id, lock: "FOR UPDATE")
              )

            with %Job{status: "waiting_human"} = current <- current,
                 %Profile{automation_status: "leased"} <- profile,
                 :ok <- JobState.validate(current.status, "running"),
                 {:ok, session} <- persist_resumed_workflow_session(current),
                 {:ok, updated} <-
                   current
                   |> Job.transition_changeset(%{
                     status: "running",
                     phase: result["phase"],
                     error: nil
                   })
                   |> Repo.update() do
              {updated, session}
            else
              nil -> Repo.rollback(:not_found)
              %Job{} -> Repo.rollback(:invalid_job_state)
              %Profile{} -> Repo.rollback(:profile_authority_conflict)
              {:error, reason} -> Repo.rollback(reason)
            end
          end)

        case result do
          {:ok, {updated, session}} ->
            :ok = Notifier.job_changed(updated.id, :control)
            if session, do: Notifier.resource_changed(:session, session.id, :resumed)
            {:ok, updated}

          {:error, reason} ->
            error(reason)
        end

      {:ok, status} ->
        finish_control(job, {:ok, Map.put(result, "status", status)}, "running")

      {:error, reason} ->
        error(reason)
    end
  end

  defp finish_resume_control(job, {:error, reason}),
    do: finish_control(job, {:error, reason}, "running")

  defp persist_resumed_workflow_session(%Job{session_id: nil}), do: {:ok, nil}

  defp persist_resumed_workflow_session(job) do
    session =
      Repo.one(from(item in Session, where: item.id == ^job.session_id, lock: "FOR UPDATE"))

    if match?(
         %Session{
           node_id: node_id,
           profile_id: profile_id,
           owner_actor_id: actor_id,
           status: "waiting_human"
         }
         when node_id == job.node_id and profile_id == job.profile_id and
                actor_id == job.requested_by_actor_id,
         session
       ) do
      session
      |> Session.changeset(%{
        mode: "automation",
        status: "ready",
        lease_id: nil,
        error: nil,
        last_seen_at: DateTime.utc_now()
      })
      |> Repo.update()
    else
      {:error, :session_mismatch}
    end
  end

  defp transition_control_job(job, attrs) do
    with {:ok, updated} <- transition_job(job, attrs),
         :ok <- maybe_release_job_profile(updated),
         :ok <- Notifier.job_changed(updated.id, :control) do
      {:ok, updated}
    end
  end

  defp cancel_queued_job(job) do
    result =
      Repo.transaction(fn ->
        locked = Repo.one(from(item in Job, where: item.id == ^job.id, lock: "FOR UPDATE"))

        with %Job{status: "queued"} = locked <- locked,
             {:ok, cancelled} <-
               locked
               |> Job.transition_changeset(%{
                 status: "cancelled",
                 completed_at: DateTime.utc_now(),
                 error: nil
               })
               |> Repo.update(),
             {1, _} <-
               Repo.update_all(from(profile in Profile, where: profile.id == ^job.profile_id),
                 set: [automation_status: "available", updated_at: DateTime.utc_now()]
               ) do
          cancelled
        else
          %Job{} -> Repo.rollback(:invalid_job_state)
          nil -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
          _unexpected -> Repo.rollback(:profile_release_failed)
        end
      end)

    result = public_result(result)

    case result do
      {:ok, cancelled} ->
        :ok = Notifier.job_changed(cancelled.id, :control)
        result

      {:error, %Error{}} ->
        result
    end
  end

  defp validate_retry_attempt(%Job{attempt: attempt}) do
    max_attempts = Application.get_env(:gsmlg_browser, :max_attempts, 3)

    if is_integer(max_attempts) and attempt < max_attempts,
      do: :ok,
      else: {:error, :max_attempts_exceeded}
  end

  defp reacquire_profile(job) do
    Repo.transaction(fn ->
      locked_job =
        Repo.one(from(current in Job, where: current.id == ^job.id, lock: "FOR UPDATE"))

      profile =
        Repo.one(
          from(profile in Profile, where: profile.id == ^job.profile_id, lock: "FOR UPDATE")
        )

      case {locked_job, profile} do
        {%Job{status: "waiting_human", profile_id: profile_id} = locked,
         %Profile{id: profile_id, automation_status: "manual"} = profile} ->
          case profile |> Profile.changeset(%{automation_status: "leased"}) |> Repo.update() do
            {:ok, _profile} -> locked
            {:error, reason} -> Repo.rollback(reason)
          end

        {%Job{status: "waiting_human", profile_id: profile_id} = locked,
         %Profile{id: profile_id, automation_status: "leased"}} ->
          locked

        {%Job{}, %Profile{}} ->
          Repo.rollback(:profile_busy)

        {nil, _profile} ->
          Repo.rollback(:not_found)

        {_job, nil} ->
          Repo.rollback(:profile_not_found)
      end
    end)
  end

  defp persist_profiles(node, remote_profiles) do
    Repo.transaction(fn ->
      current_default =
        Repo.one(
          from(profile in Profile,
            where: profile.node_id == ^node.id and profile.is_default,
            select: profile.external_id,
            lock: "FOR UPDATE"
          )
        )

      with {:ok, profiles} <- validate_remote_profiles(remote_profiles) do
        external_ids = Enum.map(profiles, & &1["id"])

        default_id =
          if current_default in external_ids, do: current_default, else: List.first(external_ids)

        Repo.update_all(from(profile in Profile, where: profile.node_id == ^node.id),
          set: [is_default: false]
        )

        Enum.map(profiles, fn remote ->
          attrs = %{
            node_id: node.id,
            external_id: remote["id"],
            name: remote["name"],
            backend: node.default_backend,
            runtime_status: remote["status"],
            is_default: remote["id"] == default_id,
            screen: remote["screen"],
            locale: remote["locale"],
            timezone: remote["timezone"],
            last_seen_at: DateTime.utc_now()
          }

          case Repo.get_by(Profile, node_id: node.id, external_id: remote["id"]) do
            nil -> %Profile{} |> Profile.changeset(attrs) |> Repo.insert!()
            profile -> profile |> Profile.changeset(attrs) |> Repo.update!()
          end
        end)
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_remote_profiles(profiles)
       when is_list(profiles) and profiles != [] and length(profiles) <= 1_000 do
    if Enum.all?(profiles, &valid_remote_profile?/1),
      do: {:ok, profiles},
      else: {:error, :invalid_rpc_response}
  end

  defp validate_remote_profiles(_profiles), do: {:error, :invalid_rpc_response}

  defp valid_remote_profile?(profile) when is_map(profile) do
    allowed = ~w(id name status screen locale timezone runtime_mode viewer_mode)

    Map.keys(profile) -- allowed == [] and is_binary(profile["id"]) and
      byte_size(profile["id"]) in 1..256 and is_binary(profile["name"]) and
      byte_size(profile["name"]) in 1..255 and
      profile["status"] in ~w(running stopped unknown unavailable) and
      is_map(profile["screen"] || %{}) and
      (is_nil(profile["locale"]) or is_binary(profile["locale"])) and
      (is_nil(profile["timezone"]) or is_binary(profile["timezone"]))
  end

  defp valid_remote_profile?(_profile), do: false

  defp normalize_profile_configuration(attrs) do
    attrs = for {key, value} <- attrs, into: %{}, do: {to_string(key), value}

    if Enum.sort(Map.keys(attrs)) == ~w(allowed_origins enabled is_default) and
         is_boolean(attrs["enabled"]) and is_boolean(attrs["is_default"]) and
         not (attrs["is_default"] and not attrs["enabled"]) and
         canonical_origins?(attrs["allowed_origins"]) do
      {:ok,
       %{
         enabled: attrs["enabled"],
         is_default: attrs["is_default"],
         allowed_origins: attrs["allowed_origins"]
       }}
    else
      {:error, :invalid_request}
    end
  end

  defp configurable_profile(%Profile{automation_status: status}, _params)
       when status in ~w(leased manual),
       do: {:error, :profile_busy}

  defp configurable_profile(%Profile{is_default: true}, %{is_default: false}),
    do: {:error, :conflict}

  defp configurable_profile(%Profile{node_id: node_id}, %{is_default: false}) do
    if Repo.exists?(
         from(profile in Profile, where: profile.node_id == ^node_id and profile.is_default)
       ),
       do: :ok,
       else: {:error, :conflict}
  end

  defp configurable_profile(_profile, _params), do: :ok

  defp select_profile_default(%Profile{node_id: node_id, id: profile_id}, true) do
    Repo.update_all(
      from(profile in Profile,
        where: profile.node_id == ^node_id and profile.id != ^profile_id and profile.is_default
      ),
      set: [is_default: false]
    )

    :ok
  end

  defp select_profile_default(_profile, false), do: :ok

  defp configured_automation_status(%Profile{automation_status: "disabled"}, true),
    do: "available"

  defp configured_automation_status(%Profile{automation_status: status}, true), do: status
  defp configured_automation_status(_profile, false), do: "disabled"

  defp mutate_profile(actor, profile_id, operation, expected_status) do
    with {:ok, _actor_id} <- actor_id(actor),
         %Profile{} = profile <- Repo.get(Profile, profile_id),
         %Node{} = node <- Repo.get(Node, profile.node_id),
         {:ok, result} <-
           CommanderBridge.call(
             node,
             operation,
             %{"profile_id" => profile.external_id},
             "#{operation}:#{profile.id}",
             DateTime.add(DateTime.utc_now(), 30, :second)
           ),
         true <-
           result["profile_id"] == profile.external_id and result["status"] == expected_status,
         {:ok, updated} <-
           profile
           |> Profile.changeset(%{runtime_status: expected_status, last_error: nil})
           |> Repo.update() do
      {:ok, updated}
    else
      nil -> error(:not_found)
      false -> error(:invalid_rpc_response)
      {:error, %Error{}} = error -> error
      {:error, :rpc_timeout} -> mark_profile_unknown(profile_id)
      {:error, reason} -> error(reason)
    end
  end

  defp mark_profile_unknown(profile_id) do
    case Repo.get(Profile, profile_id) do
      nil ->
        error(:not_found)

      profile ->
        _ =
          profile
          |> Profile.changeset(%{runtime_status: "unknown", last_error: %{"code" => "timeout"}})
          |> Repo.update()

        error(:unknown)
    end
  end

  defp normalize_session_attrs(attrs) do
    attrs = for {key, value} <- attrs, into: %{}, do: {to_string(key), value}
    required = ~w(node_id profile_id mode authorized_origins ttl_ms)
    optional = ~w(permissions)
    expected = required ++ Enum.filter(optional, &Map.has_key?(attrs, &1))

    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected) and
         match?({:ok, _}, Ecto.UUID.cast(attrs["node_id"])) and
         match?({:ok, _}, Ecto.UUID.cast(attrs["profile_id"])) and
         attrs["mode"] in ~w(automation manual) and
         valid_origins?(attrs["authorized_origins"]) and attrs["ttl_ms"] in 1..86_400_000 and
         valid_permissions?(Map.get(attrs, "permissions", %{})) do
      {:ok,
       %{
         node_id: attrs["node_id"],
         profile_id: attrs["profile_id"],
         mode: attrs["mode"],
         authorized_origins: attrs["authorized_origins"],
         ttl_ms: attrs["ttl_ms"],
         permissions: Map.get(attrs, "permissions", %{})
       }}
    else
      {:error, :invalid_request}
    end
  end

  defp valid_origins?(origins)
       when is_list(origins) and origins != [] and length(origins) <= 16 do
    origins == Enum.uniq(origins) and Enum.all?(origins, &Origin.canonical?/1)
  end

  defp valid_origins?(_origins), do: false

  defp canonical_origins?(origins)
       when is_list(origins) and origins != [] and length(origins) <= 16 do
    origins == Enum.uniq(origins) and Enum.all?(origins, &Origin.canonical?/1)
  end

  defp canonical_origins?(_origins), do: false

  defp valid_permissions?(permissions) when is_map(permissions),
    do:
      Map.keys(permissions) -- ~w(screenshot download) == [] and
        Enum.all?(Map.values(permissions), &is_boolean/1)

  defp valid_permissions?(_permissions), do: false

  defp validate_session_profile(%Profile{enabled: false}, _node_id),
    do: {:error, :profile_disabled}

  defp validate_session_profile(%Profile{enabled: true, node_id: node_id}, node_id), do: :ok

  defp validate_session_profile(%Profile{}, _node_id), do: {:error, :profile_node_mismatch}

  defp bind_session_operator(%{mode: "manual"} = params, actor_id),
    do: Map.put(params, :operator_id, actor_id)

  defp bind_session_operator(params, _actor_id), do: params

  defp insert_opening_session(actor_id, node, profile, params) do
    Repo.transaction(fn ->
      locked = Repo.one(from(item in Profile, where: item.id == ^profile.id, lock: "FOR UPDATE"))

      if locked.automation_status == "available" do
        {:ok, _profile} =
          locked |> Profile.changeset(%{automation_status: "leased"}) |> Repo.update()

        %Session{}
        |> Session.changeset(%{
          node_id: node.id,
          profile_id: profile.id,
          mode: params.mode,
          status: "opening",
          origin_policy: %{"authorized_origins" => params.authorized_origins},
          owner_actor_id: actor_id,
          expires_at: DateTime.add(DateTime.utc_now(), params.ttl_ms, :millisecond)
        })
        |> Repo.insert()
        |> case do
          {:ok, session} -> session
          {:error, reason} -> Repo.rollback(reason)
        end
      else
        Repo.rollback(:profile_busy)
      end
    end)
  end

  defp complete_session_open(session, node, profile, params) do
    payload =
      %{
        "central_session_id" => session.id,
        "profile_id" => profile.external_id,
        "mode" => params.mode,
        "authorized_origins" => params.authorized_origins,
        "ttl_ms" => params.ttl_ms,
        "permissions" => params.permissions
      }
      |> maybe_put_manual_operator(params)

    result =
      CommanderBridge.call(
        node,
        "session.open",
        payload,
        "session.open:#{session.id}",
        DateTime.add(DateTime.utc_now(), params.ttl_ms, :millisecond)
      )

    case result do
      {:ok, response} ->
        case bind_opened_session(session, profile, params, response) do
          {:ok, opened} ->
            :ok = Notifier.resource_changed(:session, opened.id, :opened)
            {:ok, opened}

          {:error, _reason} ->
            mark_session_open_unknown(session, :invalid_rpc_response)
        end

      {:error, %RPCError{} = reason} ->
        mark_session_open_failed(session, reason)

      {:error, reason} ->
        mark_session_open_unknown(session, reason)
    end
  end

  defp mark_session_open_unknown(session, _reason) do
    _ =
      session
      |> Session.changeset(%{
        status: "orphaned",
        error: %{"code" => "session_open_outcome_unknown"}
      })
      |> Repo.update()

    error(:session_outcome_unknown)
  end

  defp mark_session_open_failed(session, reason) do
    result =
      Repo.transaction(fn ->
        with {:ok, failed} <-
               session
               |> Session.changeset(%{
                 status: "failed",
                 error: %{"code" => stable_reason(reason)}
               })
               |> Repo.update(),
             {1, _} <-
               Repo.update_all(from(profile in Profile, where: profile.id == ^session.profile_id),
                 set: [automation_status: "available", updated_at: DateTime.utc_now()]
               ) do
          failed
        else
          {:error, failed_reason} -> Repo.rollback(failed_reason)
          _unexpected -> Repo.rollback(:profile_release_failed)
        end
      end)

    case result do
      {:ok, _failed} -> error(reason)
      {:error, _failure} -> error(:operation_failed)
    end
  end

  defp maybe_put_manual_operator(payload, %{mode: "manual", operator_id: operator_id}),
    do: Map.put(payload, "operator_id", operator_id)

  defp maybe_put_manual_operator(payload, _params), do: payload

  defp bind_opened_session(session, profile, params, result) do
    remote_id = result["remote_session_id"]

    if result["central_session_id"] == session.id and result["profile_id"] == profile.external_id and
         result["mode"] == session.mode and is_binary(remote_id) and
         result["status"] in ~w(ready waiting waiting_human) and
         valid_open_authority?(params, result) do
      persist_opened_session(session, params, result, remote_id)
    else
      {:error, :invalid_rpc_response}
    end
  end

  defp persist_opened_session(session, params, result, remote_id) do
    Repo.transaction(fn ->
      current = Repo.one(from(item in Session, where: item.id == ^session.id, lock: "FOR UPDATE"))

      profile =
        Repo.one(from(item in Profile, where: item.id == ^session.profile_id, lock: "FOR UPDATE"))

      with %Session{status: "opening"} = current <- current,
           %Profile{automation_status: "leased"} = profile <- profile,
           {:ok, opened} <-
             current
             |> Session.changeset(%{
               remote_session_id: remote_id,
               lease_id: result["lease_id"],
               status: result["status"],
               revision: result["revision"] || 0,
               last_seen_at: DateTime.utc_now()
             })
             |> Repo.update(),
           {:ok, _profile} <- persist_open_profile_authority(profile, params.mode) do
        opened
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
        _conflict -> Repo.rollback(:profile_authority_conflict)
      end
    end)
  end

  defp persist_open_profile_authority(profile, "manual"),
    do: profile |> Profile.changeset(%{automation_status: "manual"}) |> Repo.update()

  defp persist_open_profile_authority(profile, "automation"), do: {:ok, profile}

  defp valid_open_authority?(%{mode: "manual", operator_id: operator_id}, result) do
    result["status"] == "waiting_human" and is_binary(result["lease_id"]) and
      result["lease_owner_type"] == "manual" and result["lease_owner_id"] == operator_id
  end

  defp valid_open_authority?(%{mode: "automation"}, result) do
    result["lease_owner_type"] in [nil, "automation"] and
      (is_nil(result["lease_owner_id"]) or is_binary(result["lease_owner_id"]))
  end

  defp validate_session_identity(session, result) do
    remote = result["remote_session_id"] || result["session_id"]
    profile = Repo.get(Profile, session.profile_id)

    if match?(%Profile{}, profile) and remote == session.remote_session_id and
         result["central_session_id"] == session.id and
         result["profile_id"] == profile.external_id,
       do: :ok,
       else: {:error, :session_mismatch}
  end

  defp update_session_revision(session, result) do
    revision = result["revision"] || session.revision
    status = result["status"] || session.status

    if is_integer(revision) and revision >= session.revision and
         status in ~w(ready waiting waiting_human) do
      session
      |> Session.changeset(%{
        revision: revision,
        status: status,
        error: nil,
        last_seen_at: DateTime.utc_now()
      })
      |> Repo.update()
    else
      {:error, :stale_observation}
    end
  end

  defp normalize_action(session, action) when is_map(action) do
    action = Map.new(action, fn {key, value} -> {to_string(key), value} end)
    fields = ~w(action_id expected_revision type locator input postcondition timeout_ms)

    with true <- Enum.sort(Map.keys(action)) == Enum.sort(fields),
         type
         when type in ~w(navigate click focus fill insert_text press_key select_option scroll wait_for extract screenshot download) <-
           action["type"],
         true <- is_binary(action["action_id"]) and byte_size(action["action_id"]) in 1..200,
         :ok <- validate_expected_revision(action["expected_revision"], session.revision),
         true <- is_integer(action["timeout_ms"]) and action["timeout_ms"] in 1..120_000,
         {:ok, action_fields} <-
           lower_action_input(type, action["locator"], action["input"]),
         :ok <- validate_postcondition(action["postcondition"]) do
      remote =
        %{
          "action_id" => action["action_id"],
          "session_id" => session.remote_session_id,
          "expected_revision" => action["expected_revision"],
          "type" => type,
          "timeout_ms" => action["timeout_ms"],
          "preconditions" => []
        }
        |> Map.merge(action_fields)
        |> maybe_put_postcondition(action["postcondition"])

      {:ok, remote}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :action_not_allowed}
    end
  end

  defp normalize_action(_session, _action), do: {:error, :action_not_allowed}

  defp validate_expected_revision(expected, expected), do: :ok
  defp validate_expected_revision(_expected, _actual), do: {:error, :stale_observation}

  defp execute_remote_action(session, remote_action) do
    result =
      SessionProxy.call(
        session,
        "session.act",
        %{"session_id" => session.remote_session_id, "action" => remote_action},
        "session.act:#{session.id}:#{remote_action["action_id"]}"
      )

    case result do
      {:ok, response} ->
        with :ok <- validate_session_identity(session, response),
             {:ok, response} <-
               register_action_artifact(session, remote_action["type"], response),
             {:ok, updated} <- update_session_revision(session, response) do
          :ok = Notifier.resource_changed(:session, updated.id, :acted)
          {:ok, %{session: updated, result: response}}
        else
          {:error, _reason} -> mark_action_unknown(session)
        end

      {:error, :rpc_timeout} ->
        mark_action_unknown(session)

      {:error, %RPCError{code: "stale_observation"}} ->
        error(:stale_observation)

      {:error, %RPCError{code: "action_outcome_unknown"}} ->
        mark_action_unknown(session)

      {:error, reason} ->
        error(reason)
    end
  end

  defp register_action_artifact(
         session,
         action_type,
         %{"output" => %{"artifact" => wire} = output} = response
       )
       when is_map(wire) and map_size(output) == 1 do
    with %Node{} = node <- Repo.get(Node, session.node_id),
         {:ok, manifest} <-
           ArtifactManifest.decode(Map.put(wire, "type", "artifact.manifest")),
         true <- manifest.job_id == nil and manifest.session_id == session.id,
         true <- manifest.kind == action_artifact_kind(action_type),
         true <- manifest.metadata["remote_session_id"] == session.remote_session_id,
         {:ok, artifact} <-
           GSMLG.Browser.ArtifactService.register_pending(node.commander_id, manifest),
         :ok <- enqueue_artifact_transfer(artifact) do
      {:ok, put_in(response, ["output", "artifact"], action_artifact_reference(artifact))}
    else
      _invalid -> {:error, :invalid_artifact_manifest}
    end
  end

  defp register_action_artifact(
         _session,
         _action_type,
         %{"output" => %{"artifact" => _invalid}}
       ),
       do: {:error, :invalid_artifact_manifest}

  defp register_action_artifact(_session, _action_type, response) when is_map(response),
    do: {:ok, response}

  defp action_artifact_kind("screenshot"), do: "screenshot.png"
  defp action_artifact_kind("download"), do: "download"
  defp action_artifact_kind(_action_type), do: nil

  defp enqueue_artifact_transfer(%Artifact{id: artifact_id}) do
    case Oban.insert(ArtifactTransferWorker.new(%{"artifact_id" => artifact_id})) do
      {:ok, _oban_job} -> :ok
      {:error, _changeset} -> {:error, :artifact_transfer_enqueue_failed}
    end
  end

  defp action_artifact_reference(artifact) do
    %{
      "artifact_id" => artifact.id,
      "kind" => artifact.kind,
      "mime" => artifact.mime,
      "filename" => artifact.filename,
      "size" => artifact.size,
      "sha256" => artifact.sha256,
      "status" => artifact.status
    }
  end

  defp mark_action_unknown(session) do
    _ =
      session
      |> Session.changeset(%{
        status: "waiting",
        error: %{"code" => "action_outcome_unknown"}
      })
      |> Repo.update()

    error(:action_outcome_unknown)
  end

  defp close_remote_session(%Session{remote_session_id: remote_id} = session)
       when is_binary(remote_id) do
    case SessionProxy.call(
           session,
           "session.close",
           %{"session_id" => remote_id},
           "session.close:#{session.id}"
         ) do
      {:ok, response} ->
        with :ok <- validate_session_identity(session, response),
             true <- response["status"] == "closed",
             {:ok, closed} <-
               session
               |> Session.changeset(%{
                 status: "closed",
                 error: nil,
                 last_seen_at: DateTime.utc_now()
               })
               |> Repo.update(),
             {:ok, _profile} <- release_profile(session.profile_id) do
          :ok = Notifier.resource_changed(:session, closed.id, :closed)
          {:ok, closed}
        else
          false -> mark_close_unknown(session)
          {:error, reason} -> error(reason)
        end

      {:error, %RPCError{} = reason} ->
        error(reason)

      _unknown ->
        mark_close_unknown(session)
    end
  end

  defp close_remote_session(_session), do: error(:invalid_session_state)

  defp mark_close_unknown(session) do
    _ =
      session
      |> Session.changeset(%{
        status: "orphaned",
        error: %{"code" => "session_close_outcome_unknown"}
      })
      |> Repo.update()

    error(:close_outcome_unknown)
  end

  defp lower_action_input("navigate", nil, %{"url" => url} = input)
       when map_size(input) == 1 and is_binary(url) and byte_size(url) in 1..2_048,
       do: {:ok, %{"url" => url}}

  defp lower_action_input(type, locator, input)
       when type in ~w(click focus wait_for extract download) and input == %{} do
    with :ok <- validate_locator(locator), do: {:ok, %{"locator" => locator}}
  end

  defp lower_action_input(type, locator, %{"text" => text} = input)
       when type in ~w(fill insert_text) and map_size(input) == 1 and is_binary(text) and
              byte_size(text) <= 65_536 do
    with :ok <- validate_locator(locator),
         do: {:ok, %{"locator" => locator, "text" => text}}
  end

  defp lower_action_input("press_key", nil, %{"key" => key} = input)
       when map_size(input) == 1 and is_binary(key) and byte_size(key) in 1..64,
       do: {:ok, %{"key" => key}}

  defp lower_action_input("select_option", locator, %{"value" => value} = input)
       when map_size(input) == 1 and is_binary(value) and byte_size(value) in 1..1_024 do
    with :ok <- validate_locator(locator),
         do: {:ok, %{"locator" => locator, "value" => value}}
  end

  defp lower_action_input("scroll", nil, %{"delta_x" => x, "delta_y" => y} = input)
       when map_size(input) == 2 and is_integer(x) and is_integer(y) and
              x in -100_000..100_000 and y in -100_000..100_000,
       do: {:ok, %{"delta_x" => x, "delta_y" => y}}

  defp lower_action_input("screenshot", nil, input) when input == %{}, do: {:ok, %{}}
  defp lower_action_input(_type, _locator, _input), do: {:error, :action_not_allowed}

  defp validate_locator(%{"node_id" => value} = locator)
       when map_size(locator) == 1 and is_binary(value) and byte_size(value) in 1..256,
       do: :ok

  defp validate_locator(%{"role" => role} = locator) when map_size(locator) in [1, 2] do
    name = Map.get(locator, "accessible_name")

    if is_binary(role) and byte_size(role) in 1..128 and
         (is_nil(name) or (is_binary(name) and byte_size(name) in 1..512)) and
         Map.keys(locator) -- ~w(role accessible_name) == [],
       do: :ok,
       else: {:error, :action_not_allowed}
  end

  defp validate_locator(locator) when is_map(locator) and map_size(locator) == 1 do
    case Enum.at(locator, 0) do
      {key, value}
      when key in ~w(label placeholder text) and is_binary(value) and
             byte_size(value) in 1..512 ->
        :ok

      {"attribute", %{"name" => name, "value" => value} = attribute}
      when map_size(attribute) == 2 and name in ~w(aria-controls type) and
             is_binary(value) and byte_size(value) in 1..512 ->
        :ok

      {"css", value} when is_binary(value) and byte_size(value) in 1..1_024 ->
        if Application.get_env(:gsmlg_browser, :allow_css_locator, false),
          do: :ok,
          else: {:error, :action_not_allowed}

      _invalid ->
        {:error, :action_not_allowed}
    end
  end

  defp validate_locator(_locator), do: {:error, :action_not_allowed}

  defp validate_postcondition(nil), do: :ok

  defp validate_postcondition(%{"type" => type, "value" => value} = condition)
       when type in ~w(url_is origin_is title_contains) and map_size(condition) == 2 and
              is_binary(value) and byte_size(value) in 1..2_048,
       do: :ok

  defp validate_postcondition(%{"type" => type, "locator" => locator} = condition)
       when type in ~w(node_present node_absent) and map_size(condition) == 2,
       do: validate_locator(locator)

  defp validate_postcondition(_condition), do: {:error, :action_not_allowed}

  defp maybe_put_postcondition(remote, nil), do: remote

  defp maybe_put_postcondition(remote, postcondition),
    do: Map.put(remote, "postcondition", postcondition)

  defp manual_session_operation(actor, session_id, operation) do
    with {:ok, actor_id} <- actor_id(actor),
         {:ok, %Session{} = session} <- get_session(actor, session_id) do
      perform_manual_session_operation(session, actor_id, operation)
    else
      {:error, %Error{}} = error -> error
      {:error, reason} -> error(reason)
    end
  end

  defp perform_manual_session_operation(
         %Session{mode: "automation", status: "waiting_human", lease_id: nil} = session,
         _actor_id,
         :release
       ),
       do: {:ok, session}

  defp perform_manual_session_operation(session, actor_id, operation) do
    with :ok <- valid_manual_state(session, operation),
         remote_operation <-
           if(operation == :acquire, do: "session.manual_acquire", else: "session.manual_release"),
         payload <- manual_payload(session, actor_id, operation),
         {:ok, result} <-
           SessionProxy.call(
             session,
             remote_operation,
             payload,
             "#{remote_operation}:#{session.id}:#{actor_id}"
           ),
         :ok <- validate_session_identity(session, result),
         {:ok, updated} <- persist_manual_result(session, result, operation, actor_id) do
      :ok = Notifier.resource_changed(:session, updated.id, operation)
      {:ok, updated}
    else
      {:error, reason} -> error(reason)
    end
  end

  defp valid_manual_state(%Session{mode: "automation", status: status}, :acquire)
       when status in ~w(ready waiting waiting_human),
       do: :ok

  defp valid_manual_state(%Session{mode: "manual", status: "waiting_human"}, :acquire), do: :ok

  defp valid_manual_state(
         %Session{mode: "manual", status: "waiting_human", lease_id: lease},
         :release
       )
       when is_binary(lease),
       do: :ok

  defp valid_manual_state(_session, _operation), do: {:error, :invalid_session_state}

  defp manual_payload(session, actor_id, :acquire),
    do: %{"session_id" => session.remote_session_id, "operator_id" => actor_id}

  defp manual_payload(session, actor_id, :release),
    do: %{
      "session_id" => session.remote_session_id,
      "lease_id" => session.lease_id,
      "operator_id" => actor_id
    }

  defp persist_manual_result(session, result, :acquire, actor_id) do
    if result["status"] == "waiting_human" and is_binary(result["lease_id"]) and
         result["lease_owner_type"] == "manual" and result["lease_owner_id"] == actor_id do
      persist_manual_authority(session, actor_id, :acquire, %{
        mode: "manual",
        status: "waiting_human",
        lease_id: result["lease_id"]
      })
    else
      {:error, :invalid_rpc_response}
    end
  end

  defp persist_manual_result(session, result, :release, actor_id) do
    if result["status"] == "waiting_human" and is_nil(result["lease_id"]) and
         result["lease_owner_type"] == "released" and result["lease_owner_id"] == actor_id do
      persist_manual_authority(session, actor_id, :release, %{
        mode: "automation",
        status: "waiting_human",
        lease_id: nil
      })
    else
      {:error, :invalid_rpc_response}
    end
  end

  defp persist_manual_authority(session, actor_id, operation, attrs) do
    Repo.transaction(fn ->
      current = Repo.one(from(item in Session, where: item.id == ^session.id, lock: "FOR UPDATE"))

      profile =
        Repo.one(from(item in Profile, where: item.id == ^session.profile_id, lock: "FOR UPDATE"))

      with %Session{} = current <- current,
           %Profile{} = profile <- profile,
           :ok <- validate_manual_session_fence(current, session, actor_id, operation),
           {:ok, updated} <- persist_manual_session_state(current, attrs, operation),
           {:ok, _profile} <- persist_manual_profile_authority(profile) do
        updated
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp validate_manual_session_fence(current, supplied, actor_id, operation) do
    if current.owner_actor_id == actor_id and
         current.remote_session_id == supplied.remote_session_id and
         current.profile_id == supplied.profile_id do
      valid_persisted_manual_state(current, supplied, operation)
    else
      {:error, :session_mismatch}
    end
  end

  defp valid_persisted_manual_state(current, _supplied, :acquire),
    do: valid_manual_state(current, :acquire)

  defp valid_persisted_manual_state(
         %Session{mode: "manual", status: "waiting_human", lease_id: lease_id},
         %Session{lease_id: lease_id},
         :release
       )
       when is_binary(lease_id),
       do: :ok

  defp valid_persisted_manual_state(
         %Session{mode: "automation", status: "waiting_human", lease_id: nil},
         _supplied,
         :release
       ),
       do: :ok

  defp valid_persisted_manual_state(_current, _supplied, _operation),
    do: {:error, :invalid_session_state}

  defp persist_manual_session_state(
         %Session{mode: "automation", status: "waiting_human", lease_id: nil} = current,
         _attrs,
         :release
       ),
       do: {:ok, current}

  defp persist_manual_session_state(current, attrs, _operation),
    do: current |> Session.changeset(attrs) |> Repo.update()

  defp persist_manual_profile_authority(%Profile{automation_status: "manual"} = profile),
    do: {:ok, profile}

  defp persist_manual_profile_authority(%Profile{automation_status: "leased"} = profile),
    do: profile |> Profile.changeset(%{automation_status: "manual"}) |> Repo.update()

  defp persist_manual_profile_authority(%Profile{}),
    do: {:error, :profile_authority_conflict}

  defp release_profile(profile_id) do
    case Repo.get(Profile, profile_id) do
      nil -> :ok
      profile -> profile |> Profile.changeset(%{automation_status: "available"}) |> Repo.update()
    end
  end

  defp synchronize_live_nodes(live, opts) do
    result =
      live
      |> Enum.sort_by(fn {commander_id, _entry} -> commander_id end)
      |> Enum.take(@live_node_limit)
      |> Enum.reduce_while({:ok, []}, fn {commander_id, entry}, {:ok, nodes} ->
        case synchronize_live_node(commander_id, entry, opts) do
          {:ok, node} -> {:cont, {:ok, [{node, entry} | nodes]}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, nodes} -> refresh_live_nodes(Enum.reverse(nodes), opts)
      {:error, _reason} = error -> error
    end
  end

  defp synchronize_live_node(commander_id, %{agent: agent, capability: descriptor}, _opts) do
    tls_metadata = live_tls_metadata(agent)

    attrs = %{
      commander_id: commander_id,
      default_backend: descriptor["backend"],
      status: "degraded",
      capabilities: [descriptor],
      limits: descriptor["limits"],
      last_seen_at: heartbeat_datetime(agent[:last_heartbeat]),
      metadata: tls_metadata
    }

    with {:ok, _candidate} <-
           %Node{}
           |> Node.changeset(attrs)
           |> Repo.insert(on_conflict: :nothing, conflict_target: :commander_id),
         %Node{} = node <- Repo.get_by(Node, commander_id: commander_id),
         {:ok, node} <-
           node
           |> Node.changeset(
             attrs
             |> Map.drop([:commander_id, :status])
             |> Map.put(
               :metadata,
               node.metadata
               |> drop_tls_metadata()
               |> Map.merge(tls_metadata)
             )
           )
           |> Repo.update() do
      {:ok, node}
    else
      nil -> {:error, :node_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp refresh_live_nodes(nodes, opts) do
    refreshable =
      Enum.filter(nodes, fn {node, %{capability: descriptor}} ->
        node.enabled and "manager.status" in descriptor["operations"]
      end)

    results =
      Task.async_stream(
        refreshable,
        fn {node, %{agent: agent}} -> manager_status(node, agent, opts) end,
        max_concurrency: @live_node_limit,
        ordered: true,
        on_timeout: :kill_task,
        timeout: @manager_status_task_timeout_ms
      )

    refreshable
    |> Enum.zip(results)
    |> Enum.reduce_while(:ok, fn
      {{node, %{agent: agent}}, {:ok, result}}, :ok ->
        case persist_manager_status(node, result, live_tls_metadata(agent)) do
          {:ok, _node} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      {{node, %{agent: agent}}, {:exit, _reason}}, :ok ->
        case persist_manager_failure(node, :rpc_timeout, live_tls_metadata(agent)) do
          {:ok, _node} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
    end)
  end

  defp manager_status(node, agent, opts) do
    deadline = DateTime.add(DateTime.utc_now(), @manager_status_timeout_ms, :millisecond)
    generation = agent[:generation] || agent[:connected_at] || "initial"

    CommanderBridge.call(
      node,
      "manager.status",
      %{},
      "manager.status:#{node.id}:#{generation}",
      deadline,
      opts
      |> Keyword.take([:dispatch])
      |> Keyword.put(:timeout, @manager_status_timeout_ms)
    )
  end

  defp persist_manager_status(node, {:ok, result}, tls_metadata) do
    case safe_manager_status(result, node.default_backend) do
      {:ok, status, metadata, last_error} ->
        node
        |> Node.changeset(%{
          status: status,
          metadata: Map.merge(metadata, tls_metadata),
          last_error: last_error
        })
        |> Repo.update()

      {:error, reason} ->
        persist_manager_failure(node, reason, tls_metadata)
    end
  end

  defp persist_manager_status(node, {:error, reason}, tls_metadata),
    do: persist_manager_failure(node, reason, tls_metadata)

  defp persist_manager_failure(node, reason, tls_metadata) do
    node
    |> Node.changeset(%{
      status: "degraded",
      metadata:
        node.metadata
        |> drop_tls_metadata()
        |> Map.put("manager_status", "degraded")
        |> Map.merge(tls_metadata),
      last_error: %{"code" => safe_manager_error_code(reason)}
    })
    |> Repo.update()
  end

  defp safe_manager_status(result, backend) when is_map(result) do
    with status when status in ~w(available degraded) <- result["status"],
         ^backend <- result["backend"],
         {:ok, agent_version} <- bounded_metadata_string(result["agent_version"], 128),
         {:ok, browser_version} <- optional_metadata_string(result["binary_version"], 128),
         {:ok, profiles_total} <- optional_bounded_count(result["profiles_total"]),
         {:ok, running_count} <- optional_bounded_count(result["running_count"]),
         {:ok, runtime_mode} <- optional_metadata_string(result["runtime_mode"], 64) do
      metadata =
        %{
          "manager_status" => status,
          "agent_version" => agent_version
        }
        |> put_optional_metadata("browser_version", browser_version)
        |> put_optional_metadata("profiles_total", profiles_total)
        |> put_optional_metadata("running_count", running_count)
        |> put_optional_metadata("runtime_mode", runtime_mode)

      node_status = if status == "available", do: "online", else: "degraded"
      last_error = if status == "degraded", do: %{"code" => safe_error_code(result)}, else: nil
      {:ok, node_status, metadata, last_error}
    else
      _invalid -> {:error, :invalid_rpc_response}
    end
  end

  defp safe_manager_status(_result, _backend), do: {:error, :invalid_rpc_response}

  defp live_tls_metadata(%{info: info}) when is_map(info) do
    summary = Map.get(info, :tls) || Map.get(info, "tls")

    case TLSSummary.validate(summary) do
      {:ok, %{"status" => status} = summary} ->
        %{"tls_status" => status}
        |> put_tls_expiry(summary["certificate_expires_at"])

      {:error, :invalid_tls_summary} ->
        %{}
    end
  end

  defp live_tls_metadata(_agent), do: %{}

  defp put_tls_expiry(metadata, nil), do: metadata

  defp put_tls_expiry(metadata, expires_at) do
    {:ok, expiry, 0} = DateTime.from_iso8601(expires_at)

    remaining_seconds =
      expiry
      |> DateTime.diff(DateTime.utc_now(), :second)
      |> max(0)
      |> min(@max_tls_remaining_seconds)

    Map.merge(metadata, %{
      "tls_expires_at" => expires_at,
      "tls_remaining_seconds" => remaining_seconds
    })
  end

  defp drop_tls_metadata(nil), do: %{}
  defp drop_tls_metadata(metadata), do: Map.drop(metadata, @tls_metadata_keys)

  defp safe_browser_capability(capability) when is_map(capability) do
    backend = capability_field(capability, :backend)
    operations = capability_field(capability, :operations)
    limits = capability_field(capability, :limits)
    workflows = capability_field(capability, :workflows)

    with {:ok, backend} <- bounded_metadata_string(backend, 255),
         true <- is_list(operations) and length(operations) <= 64,
         true <- Enum.all?(operations, &bounded_metadata_string?(&1, 128)),
         {:ok, limits} <- safe_capability_limits(limits),
         true <- is_list(workflows) and length(workflows) <= 32,
         true <- Enum.all?(workflows, &bounded_metadata_string?(&1, 256)) do
      {:ok,
       %{
         "id" => "browser.control",
         "version" => 1,
         "backend" => backend,
         "operations" => operations,
         "limits" => limits,
         "workflows" => workflows
       }}
    else
      _invalid -> {:error, :invalid_rpc_response}
    end
  end

  defp safe_browser_capability(_capability), do: {:error, :invalid_rpc_response}

  defp safe_capability_limits(limits) when is_map(limits) do
    allowed = ~w(max_profiles_running max_sessions max_workflows)

    if Map.keys(limits) -- allowed == [] and
         Enum.all?(limits, fn {_key, value} -> is_integer(value) and value in 0..1_000 end) do
      {:ok, Map.take(limits, allowed)}
    else
      {:error, :invalid_rpc_response}
    end
  end

  defp safe_capability_limits(_limits), do: {:error, :invalid_rpc_response}

  defp bounded_metadata_string?(value, maximum),
    do: match?({:ok, _value}, bounded_metadata_string(value, maximum))

  defp bounded_metadata_string(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: {:ok, value}

  defp bounded_metadata_string(_value, _maximum), do: {:error, :invalid_rpc_response}

  defp optional_metadata_string(nil, _maximum), do: {:ok, nil}
  defp optional_metadata_string(value, maximum), do: bounded_metadata_string(value, maximum)

  defp optional_bounded_count(nil), do: {:ok, nil}

  defp optional_bounded_count(value) when is_integer(value) and value in 0..1_000_000,
    do: {:ok, value}

  defp optional_bounded_count(_value), do: {:error, :invalid_rpc_response}

  defp put_optional_metadata(metadata, _key, nil), do: metadata
  defp put_optional_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  defp safe_error_code(%{"error_code" => code}), do: safe_manager_error_code(code)
  defp safe_error_code(_result), do: "manager_unavailable"

  defp safe_manager_error_code(%RPCError{code: code}), do: safe_manager_error_code(code)

  defp safe_manager_error_code(code) when is_atom(code),
    do: safe_manager_error_code(Atom.to_string(code))

  defp safe_manager_error_code(code) when is_binary(code) and byte_size(code) <= 128 do
    if Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, code), do: code, else: "manager_unavailable"
  end

  defp safe_manager_error_code(_reason), do: "manager_unavailable"

  defp live_browser_agents(registry) do
    registry.list_agents()
    |> Enum.reduce(%{}, fn agent, live ->
      capability =
        agent
        |> agent_capability_descriptors()
        |> List.wrap()
        |> Enum.find(
          &(capability_field(&1, :id) == "browser.control" and capability_field(&1, :version) == 1)
        )

      case safe_browser_capability(capability) do
        {:ok, descriptor} ->
          Map.put(live, agent.agent_id, %{agent: agent, capability: descriptor})

        {:error, _invalid_descriptor} ->
          live
      end
    end)
  end

  defp merge_live_node(%Node{enabled: false} = node, _live), do: %{node | status: "disabled"}

  defp merge_live_node(node, live) do
    case live[node.commander_id] do
      nil ->
        %{node | online?: false, status: "offline", metadata: drop_tls_metadata(node.metadata)}

      %{agent: agent, capability: capability} ->
        %{
          node
          | online?: true,
            status: if(node.status == "degraded", do: "degraded", else: "online"),
            capabilities: [capability],
            limits: capability_field(capability, :limits) || %{},
            last_seen_at: heartbeat_datetime(agent[:last_heartbeat]) || node.last_seen_at,
            metadata:
              node.metadata
              |> drop_tls_metadata()
              |> Map.merge(live_tls_metadata(agent))
        }
    end
  end

  defp capability_field(capability, key) when is_map(capability),
    do: Map.get(capability, key) || Map.get(capability, Atom.to_string(key))

  defp agent_capability_descriptors(%{info: info}) when is_map(info) do
    case Map.fetch(info, :capability_descriptors) do
      {:ok, descriptors} -> descriptors
      :error -> Map.get(info, :capabilities, [])
    end
  end

  defp agent_capability_descriptors(_agent), do: []

  defp heartbeat_datetime(value) when is_integer(value) and value > 1_000_000_000,
    do: DateTime.from_unix!(value, :millisecond)

  defp heartbeat_datetime(_value), do: nil

  defp result_status(%{"status" => status})
       when status in ~w(accepted running waiting_human collecting_artifacts completed failed cancelled),
       do: {:ok, status}

  defp result_status(_result), do: {:error, :invalid_rpc_response}

  defp terminal_time(status) when status in ~w(completed failed cancelled), do: DateTime.utc_now()
  defp terminal_time(_status), do: nil

  defp bounded_limit(opts) do
    case Keyword.get(opts, :limit, 50) do
      value when is_integer(value) and value > 0 -> min(value, 100)
      _invalid -> 50
    end
  end

  defp after_id(query, cursor) when is_binary(cursor),
    do: from(item in query, where: item.id > ^cursor)

  defp after_id(query, _cursor), do: query

  defp validate_id_cursor(nil), do: :ok
  defp validate_id_cursor(cursor), do: validate_uuid(cursor)

  defp validate_sequence_cursor(nil), do: :ok

  defp validate_sequence_cursor(sequence) when is_integer(sequence) and sequence >= 0, do: :ok

  defp validate_sequence_cursor(_sequence), do: error(:invalid_request)

  defp validate_uuid(value) when is_binary(value) do
    if match?({:ok, _uuid}, Ecto.UUID.cast(value)), do: :ok, else: error(:invalid_request)
  end

  defp validate_uuid(_value), do: error(:invalid_request)

  defp browser_node_online?(node) do
    case AgentRegistry.find_agent(node.commander_id) do
      {:ok, agent} ->
        agent
        |> agent_capability_descriptors()
        |> List.wrap()
        |> Enum.any?(fn capability ->
          capability_field(capability, :id) == "browser.control" and
            capability_field(capability, :version) == 1
        end)

      _offline ->
        false
    end
  end

  defp default_deadline do
    milliseconds = Application.get_env(:gsmlg_browser, :default_deadline_ms, 3_600_000)
    DateTime.add(DateTime.utc_now(), milliseconds, :millisecond)
  end

  defp artifact_source(%Artifact{storage_type: "inline", inline_content: content}),
    do:
      if(is_binary(content),
        do: {:ok, {:inline, content}},
        else: {:error, :artifact_not_verified}
      )

  defp artifact_source(%Artifact{storage_type: "storage", storage_ref: storage_ref}),
    do:
      if(is_binary(storage_ref),
        do: {:ok, {:storage, storage_ref}},
        else: {:error, :artifact_not_verified}
      )

  defp artifact_source(%Artifact{}), do: {:error, :artifact_not_verified}

  defp validate_range(first, last, size)
       when is_integer(first) and is_integer(last) and first >= 0 and last >= first and
              last < size,
       do: :ok

  defp validate_range(_first, _last, _size), do: error(:invalid_range)

  defp storage_result({:ok, content}), do: {:ok, content}
  defp storage_result({:error, _reason}), do: error(:storage_failed)

  defp actor_id(%{id: id}) when is_binary(id) and id != "" do
    case Enabled.ensure() do
      :ok -> {:ok, id}
      {:error, reason} -> error(reason)
    end
  end

  defp actor_id(_actor), do: error(:actor_required)

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> :unknown
    end
  end

  defp stable_reason(%RPCError{}), do: "remote_error"
  defp stable_reason(%{code: _code}), do: "remote_error"
  defp stable_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp stable_reason(_reason), do: "remote_error"

  defp public_result({:ok, value}), do: {:ok, value}
  defp public_result({:error, reason}), do: error(reason)

  defp notify_job_result({:ok, %Job{} = job} = result, reason) do
    :ok = Notifier.job_changed(job.id, reason)
    result
  end

  defp notify_job_result(result, _reason), do: result

  defp error(%Error{} = error), do: {:error, error}
  defp error(reason), do: error(reason, nil)

  defp error(%Ecto.Changeset{} = changeset, _message) do
    {:error,
     Error.new(
       "validation",
       "invalid_request",
       "The browser request is invalid.",
       false,
       "correct_request",
       %{fields: changeset_errors(changeset)}
     )}
  end

  defp error(reason, _message) do
    {class, code, message, retryable, human_action} = error_fields(reason)
    {:error, Error.new(class, code, message, retryable, human_action)}
  end

  defp error_fields(reason)
       when reason in [
              :actor_required,
              :invalid_request,
              :invalid_chat_url,
              :invalid_workflow_input,
              :unsupported_workflow
            ],
       do:
         {"validation", Atom.to_string(reason), "The browser request is invalid.", false,
          "correct_request"}

  defp error_fields(reason)
       when reason in [:not_found, :node_not_found, :profile_not_found],
       do:
         {"not_found", Atom.to_string(reason), "The requested browser resource was not found.",
          false, "check_resource"}

  defp error_fields(reason)
       when reason in [
              :profile_busy,
              :node_offline,
              :rpc_timeout,
              :unknown,
              :invalid_rpc_response,
              :storage_failed
            ],
       do:
         {"availability", Atom.to_string(reason),
          "The browser resource is temporarily unavailable.", true, "retry_or_reconcile"}

  defp error_fields(:service_unavailable),
    do:
      {"availability", "service_unavailable", "The browser service is unavailable.", true,
       "contact_administrator"}

  defp error_fields(reason)
       when reason in [
              :profile_disabled,
              :node_disabled,
              :job_terminal,
              :illegal_job_transition,
              :artifact_not_verified,
              :invalid_range,
              :invalid_session_state,
              :invalid_job_state,
              :job_not_bound,
              :action_not_allowed
            ],
       do:
         {"state", Atom.to_string(reason),
          "The browser resource is not in a valid state for this operation.", false,
          "refresh_state"}

  defp error_fields(reason)
       when reason in [:action_outcome_unknown, :session_outcome_unknown, :close_outcome_unknown],
       do:
         {"state", Atom.to_string(reason),
          "The remote browser outcome is unknown and must be reconciled.", false, "reconcile"}

  defp error_fields(:max_attempts_exceeded),
    do:
      {"state", "max_attempts_exceeded", "The browser job retry limit has been reached.", false,
       "review_job"}

  defp error_fields(reason)
       when reason in [
              :idempotency_conflict,
              :profile_node_mismatch,
              :session_mismatch,
              :job_mismatch,
              :execution_mismatch,
              :stale_observation,
              :conflict
            ],
       do:
         {"conflict", Atom.to_string(reason),
          "The request conflicts with existing browser state.", false, "use_matching_identity"}

  defp error_fields(_reason),
    do:
      {"internal", "operation_failed", "The browser operation failed.", false,
       "contact_administrator"}

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, _opts} -> message end)
  end
end
