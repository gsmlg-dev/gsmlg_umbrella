defmodule GSMLG.BrowserAgent.SessionRunner do
  @moduledoc false

  use GenServer, restart: :transient

  alias GSMLG.BrowserAgent.{Journal, ProfileLease, ProfileLeaseServer, SafeBrowser}
  alias GSMLG.BrowserAgent.Backends.CloakBrowser
  alias GSMLG.BrowserAgent.CDP.Client
  alias GSMLG.BrowserAgent.SafeBrowser.CDP

  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)
    name = {:via, Registry, {Keyword.fetch!(opts, :registry_name), session.remote_session_id}}
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def child_spec(opts) do
    session = Keyword.fetch!(opts, :session)

    %{
      id: {__MODULE__, session.remote_session_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient
    }
  end

  @impl true
  def init(opts) do
    supplied = Keyword.fetch!(opts, :session)
    journal = Keyword.fetch!(opts, :journal)

    persisted =
      case Journal.get(journal, :browser_session, supplied.remote_session_id) do
        {:ok, session} -> session
        :error -> nil
      end

    state = %{
      session: persisted || supplied,
      browser: nil,
      browser_resource: nil,
      journal: journal,
      lease_server: Keyword.fetch!(opts, :lease_server),
      settings: Keyword.fetch!(opts, :settings),
      browser_factory: Keyword.get(opts, :browser_factory),
      browser_closer: Keyword.get(opts, :browser_closer),
      backend: Keyword.get(opts, :backend) || CloakBrowser,
      backend_opts: Keyword.get(opts, :backend_opts, []),
      cdp_client_opts: Keyword.get(opts, :cdp_client_opts, []),
      cdp_supervisor_name: Keyword.fetch!(opts, :cdp_supervisor_name),
      cdp_supervisor_monitor: monitor_process(Keyword.fetch!(opts, :cdp_supervisor_name)),
      client_monitor: nil,
      expiry_timer: nil,
      expiry_token: nil
    }

    case if(persisted, do: recover(state), else: open(state)) do
      {:ok, state} -> {:ok, schedule_expiry(state)}
      {:error, state} -> {:ok, schedule_expiry(state)}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, %{session: %{status: :failed}} = state),
    do: {:stop, :normal, {:error, :session_open_failed}, state}

  def handle_call(
        :snapshot,
        _from,
        %{session: %{status: :orphaned, observation: nil}} = state
      ),
      do: {:reply, {:error, :session_open_failed}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, snapshot(state.session)}, state}

  def handle_call(:observe, _from, %{session: %{status: :ready}} = state) do
    case SafeBrowser.observe(state.browser) do
      {:ok, observation, browser} ->
        state = update_session(%{state | browser: browser}, :ready, observation)
        {:reply, {:ok, Map.merge(snapshot(state.session), observation)}, state}

      {:error, reason, browser} ->
        state = %{state | browser: browser} |> persist_status(:orphaned)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:observe, _from, state), do: {:reply, {:error, :session_not_ready}, state}

  def handle_call({:act, action}, _from, %{session: %{status: :ready}} = state) do
    state = persist_status(state, :acting)

    case SafeBrowser.execute(state.browser, action) do
      {:ok, result, browser} ->
        state =
          state
          |> Map.put(:browser, browser)
          |> update_session(:ready, browser.observation)

        {:reply, {:ok, Map.merge(snapshot(state.session), result)}, state}

      {:error, :action_outcome_unknown = reason, browser} ->
        state =
          %{state | browser: browser} |> sync_browser_observation() |> persist_status(:orphaned)

        {:reply, {:error, reason}, state}

      {:error, reason, browser} ->
        status = if browser_reconcile_required?(reason), do: :orphaned, else: :ready

        state =
          %{state | browser: browser} |> sync_browser_observation() |> persist_status(status)

        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:act, _action}, _from, state),
    do: {:reply, {:error, :session_not_ready}, state}

  def handle_call({:manual_handoff, operator_id}, _from, %{session: %{status: :ready}} = state)
      when is_binary(operator_id) and operator_id != "" do
    reply_manual_handoff(state, operator_id)
  end

  def handle_call({:manual_handoff, _operator_id}, _from, state),
    do: {:reply, {:error, :session_not_ready}, state}

  def handle_call({:manual_acquire, operator_id}, _from, %{session: %{status: :ready}} = state)
      when is_binary(operator_id) and operator_id != "" do
    reply_manual_handoff(state, operator_id)
  end

  def handle_call(
        {:manual_acquire, operator_id},
        _from,
        %{session: %{status: :waiting_human}} = state
      )
      when is_binary(operator_id) and operator_id != "" do
    case manual_lease(state) do
      {:ok, %ProfileLease{owner_id: ^operator_id}} ->
        {:reply, {:ok, snapshot(state.session)}, state}

      {:ok, %ProfileLease{owner_type: :manual}} ->
        {:reply, {:error, :operator_identity_mismatch}, state}

      :error ->
        acquire_unclaimed_manual(state, operator_id)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:manual_acquire, _operator_id}, _from, state),
    do: {:reply, {:error, :session_not_waiting_human}, state}

  def handle_call(
        {:manual_release, lease_id, operator_id},
        _from,
        %{session: %{status: :waiting_human}} = state
      )
      when is_binary(lease_id) and lease_id != "" and is_binary(operator_id) and
             operator_id != "" do
    release_manual(state, lease_id, operator_id)
  end

  def handle_call({:manual_release, _lease_id, _operator_id}, _from, state),
    do: {:reply, {:error, :session_not_waiting_human}, state}

  def handle_call(:resume_automation, _from, %{session: %{status: :waiting_human}} = state) do
    session = state.session

    with {:ok, lease} <- resume_lease(state),
         {:ok, state} <-
           ensure_browser(%{state | session: %{session | lease_id: lease.lease_id}}),
         browser = %{state.browser | lease_id: lease.lease_id},
         {:ok, observation, browser} <- SafeBrowser.observe(browser) do
      state =
        %{state | browser: browser}
        |> persist_lease(lease, :ready)
        |> update_session(:ready, observation)

      {:reply, {:ok, snapshot(state.session)}, state}
    else
      {:error, reason, %SafeBrowser{} = browser} ->
        {:reply, {:error, reason}, %{state | browser: browser} |> persist_status(:orphaned)}

      {:error, reason} ->
        {:reply, {:error, reason}, persist_status(state, :orphaned)}
    end
  end

  def handle_call(:resume_automation, _from, state),
    do: {:reply, {:error, :session_not_waiting_human}, state}

  def handle_call(:reconcile, _from, state) do
    state = reconcile_state(state)
    {:reply, {:ok, snapshot(state.session)}, state}
  end

  def handle_call(:close, _from, state) do
    state = persist_status(state, :closing)

    case close_browser(state) do
      :ok ->
        case release_active_lease(state) do
          :ok ->
            state = persist_status(state, :closed)
            {:stop, :normal, {:ok, snapshot(state.session)}, state}

          {:error, reason} ->
            state = persist_status(state, :orphaned)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        state = mark_close_uncertain(state)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:session_expired, token}, %{expiry_token: token} = state) do
    state = persist_status(state, :closing)

    case close_browser(state) do
      :ok ->
        case release_active_lease(state) do
          :ok -> {:stop, :normal, clear_close_uncertain(state, :closed)}
          {:error, _reason} -> {:noreply, mark_close_uncertain(state)}
        end

      {:error, _reason} ->
        {:noreply, mark_close_uncertain(state)}
    end
  end

  def handle_info({:session_expired, _stale_token}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{client_monitor: ref} = state) do
    state =
      state
      |> Map.merge(%{browser: nil, client_monitor: nil})
      |> persist_status(:orphaned)

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{cdp_supervisor_monitor: ref} = state
      ) do
    state =
      state
      |> clear_client_monitor()
      |> Map.merge(%{
        browser: nil,
        browser_resource: nil,
        cdp_supervisor_monitor: nil
      })
      |> persist_status(:orphaned)

    {:noreply, state}
  end

  @doc false
  def snapshot(session) do
    %{
      "central_session_id" => session.central_session_id,
      "remote_session_id" => session.remote_session_id,
      "profile_id" => session.profile_id,
      "mode" => Atom.to_string(session.mode),
      "status" => Atom.to_string(session.status),
      "revision" => session.revision,
      "lease_id" => session.lease_id,
      "expires_at" => DateTime.to_iso8601(session.expires_at)
    }
    |> Map.merge(lease_identity(session))
  end

  defp open(state) do
    session = state.session
    :ok = Journal.put(state.journal, :browser_session, session.remote_session_id, session)

    {owner_type, owner_id} =
      if session.mode == :manual,
        do: {:manual, session.requested_operator_id},
        else: {:automation, session.remote_session_id}

    case ProfileLeaseServer.acquire(
           state.lease_server,
           session.profile_id,
           owner_type,
           owner_id,
           mode: session.mode,
           ttl_ms: session.ttl_ms
         ) do
      {:ok, lease} ->
        state = persist_lease(state, lease, :opening)

        case ensure_browser(state) do
          {:ok, state} when session.mode == :manual ->
            {:ok, persist_lease(state, lease, :waiting_human)}

          {:ok, state} ->
            initial_ready_state(state)

          {:error, _reason} ->
            cleanup_failed_open(state)
        end

      {:error, _reason} ->
        {:error, persist_status(state, :failed)}
    end
  end

  defp recover(state) do
    :ok = SafeBrowser.recover_actions(state.journal, state.session.remote_session_id)
    {:ok, state |> recover_manual_release() |> reconcile_state()}
  end

  defp reconcile_state(state) do
    cond do
      state.session.status == :closing or Map.get(state.session, :close_uncertain, false) ->
        reconcile_uncertain_close(state)

      state.session.status == :waiting_human and is_nil(state.session.lease_id) and
          is_map(Map.get(state.session, :manual_released)) ->
        persist_status(state, :waiting_human)

      unresolved_action?(state) ->
        persist_status(state, :orphaned)

      true ->
        reconcile_lease(state)
    end
  end

  defp reconcile_lease(state) do
    case ProfileLeaseServer.get(state.lease_server, state.session.profile_id) do
      {:ok,
       %ProfileLease{
         owner_type: :automation,
         owner_id: owner,
         lease_id: lease_id,
         expires_at: expires_at
       }}
      when owner == state.session.remote_session_id ->
        state =
          state
          |> Map.put(:session, %{state.session | lease_id: lease_id, expires_at: expires_at})
          |> ensure_cdp_supervisor_monitor()

        case validate_remote_profile(state) do
          :ok -> reconcile_browser(state)
          {:error, _reason} -> persist_status(state, :orphaned)
        end

      {:ok,
       %ProfileLease{
         owner_type: :manual,
         lease_id: lease_id,
         suspended: %ProfileLease{owner_id: owner}
       }}
      when owner == state.session.remote_session_id ->
        state
        |> Map.put(:session, %{state.session | lease_id: lease_id})
        |> persist_status(:waiting_human)

      {:ok,
       %ProfileLease{
         owner_type: :manual,
         owner_id: owner,
         lease_id: lease_id,
         expires_at: expires_at
       }}
      when owner == state.session.requested_operator_id ->
        state
        |> Map.put(
          :session,
          Map.merge(state.session, %{
            lease_id: lease_id,
            expires_at: expires_at,
            manual_holder_id: owner
          })
        )
        |> ensure_cdp_supervisor_monitor()
        |> persist_status(:waiting_human)

      _missing_or_changed ->
        state |> Map.put(:browser, nil) |> persist_status(:orphaned)
    end
  end

  defp ensure_browser(%{browser: %SafeBrowser{}} = state), do: {:ok, state}

  defp ensure_browser(%{browser_factory: factory} = state) when is_function(factory, 1) do
    opts = [
      session_id: state.session.remote_session_id,
      central_session_id: state.session.central_session_id,
      profile_id: state.session.profile_id,
      lease_id: state.session.lease_id,
      revision: state.session.revision,
      observation: state.session.observation,
      artifact_job_id: state.session.artifact_job_id,
      artifact_remote_execution_id: state.session.artifact_remote_execution_id,
      origin_policy: state.session.origin_policy,
      permissions: state.session.permissions,
      allow_css_locator: state.settings.allow_css_locator,
      cdp_supervisor: state.cdp_supervisor_name
    ]

    case factory.(opts) do
      {:ok, %SafeBrowser{} = browser} ->
        {:ok, %{state | browser: browser}}

      {:ok, %SafeBrowser{} = browser, resource} ->
        {:ok, %{state | browser: browser, browser_resource: resource}}

      _error ->
        {:error, :session_open_failed}
    end
  rescue
    _exception -> {:error, :session_open_failed}
  catch
    _kind, _reason -> {:error, :session_open_failed}
  end

  defp ensure_browser(state), do: open_production_browser(state)

  defp reset_production_browser(%{browser_resource: %{client: client}} = state) do
    state = clear_client_monitor(state)
    _ = terminate_cdp_client(state.cdp_supervisor_name, client)
    %{state | browser: nil, browser_resource: nil}
  end

  defp reset_production_browser(state),
    do: state |> clear_client_monitor() |> Map.merge(%{browser: nil, browser_resource: nil})

  defp open_production_browser(state) do
    case state.backend.open_session(state.settings, state.session.profile_id, state.backend_opts) do
      {:ok, backend_session} -> connect_production_browser(state, backend_session)
      _error -> {:error, :session_open_failed}
    end
  end

  defp connect_production_browser(state, backend_session) do
    case state.backend.connect_control_protocol(
           state.settings,
           backend_session,
           state.backend_opts
         ) do
      {:ok, connection} -> start_production_client(state, backend_session, connection)
      _error -> cleanup_backend_session(state, backend_session)
    end
  end

  defp start_production_client(state, backend_session, connection) do
    client_opts =
      Keyword.merge(
        [
          id: state.session.remote_session_id,
          owner: self(),
          url: connection.url,
          headers: connection.headers,
          max_message_bytes: state.settings.max_response_bytes,
          origin_policy: state.session.origin_policy,
          download_dir: download_directory(state),
          max_download_bytes: state.settings.max_response_bytes,
          transport_opts: [
            connect_timeout: state.settings.manager_connect_timeout_ms,
            handshake_timeout: state.settings.request_timeout_ms
          ]
        ],
        state.cdp_client_opts
      )

    case start_cdp_client(state.cdp_supervisor_name, client_opts) do
      {:ok, client} -> initialize_production_client(state, backend_session, client)
      _error -> cleanup_backend_session(state, backend_session)
    end
  end

  defp start_cdp_client(supervisor, opts) do
    DynamicSupervisor.start_child(supervisor, {Client, opts})
  catch
    :exit, _reason -> {:error, :cdp_supervisor_unavailable}
  end

  defp initialize_production_client(state, backend_session, client) do
    timeout = state.settings.request_timeout_ms

    with :ok <- Client.await_ready(client, timeout),
         :ok <- Client.enable(client, timeout),
         {:ok, browser} <-
           SafeBrowser.new(
             session_id: state.session.remote_session_id,
             central_session_id: state.session.central_session_id,
             profile_id: state.session.profile_id,
             lease_id: state.session.lease_id,
             journal: state.journal,
             lease_server: state.lease_server,
             client: client,
             adapter: CDP,
             origin_policy: state.session.origin_policy,
             clock: &DateTime.utc_now/0,
             revision: state.session.revision,
             observation: state.session.observation,
             artifact_job_id: state.session.artifact_job_id,
             artifact_remote_execution_id: state.session.artifact_remote_execution_id,
             allow_css_locator: state.settings.allow_css_locator,
             allow_screenshots: state.session.permissions.screenshot,
             allow_downloads: state.session.permissions.download,
             state_dir: state.settings.state_dir,
             max_artifact_bytes: state.settings.max_artifact_bytes,
             max_observation_bytes: state.settings.max_observation_bytes
           ) do
      {:ok,
       %{
         state
         | browser: browser,
           browser_resource: %{client: client, backend_session: backend_session},
           client_monitor: Process.monitor(client)
       }}
    else
      _error ->
        _ = terminate_cdp_client(state.cdp_supervisor_name, client)
        cleanup_backend_session(state, backend_session)
    end
  end

  defp cleanup_backend_session(state, backend_session) do
    _ = state.backend.close_session(state.settings, backend_session, state.backend_opts)
    {:error, :session_open_failed}
  catch
    _kind, _reason -> {:error, :session_open_failed}
  end

  defp download_directory(state) do
    digest =
      :crypto.hash(:sha256, state.session.remote_session_id)
      |> Base.url_encode64(padding: false)

    Path.join([state.settings.state_dir, "browser-downloads", digest])
  end

  defp close_browser(%{browser_closer: closer} = state) when is_function(closer, 3) do
    normalize_close(closer.(state.browser, state.browser_resource, state.session))
  rescue
    _exception -> {:error, :session_close_unconfirmed}
  catch
    _kind, _reason -> {:error, :session_close_unconfirmed}
  end

  defp close_browser(%{browser_closer: closer} = state) when is_function(closer, 2) do
    normalize_close(closer.(state.browser, state.session))
  rescue
    _exception -> {:error, :session_close_unconfirmed}
  catch
    _kind, _reason -> {:error, :session_close_unconfirmed}
  end

  defp close_browser(
         %{browser_resource: %{client: client, backend_session: backend_session}} = state
       ) do
    _ = clear_client_monitor(state)
    _ = terminate_cdp_client(state.cdp_supervisor_name, client)

    state.backend.close_session(state.settings, backend_session, state.backend_opts)
    |> normalize_close()
  rescue
    _exception -> {:error, :session_close_unconfirmed}
  catch
    _kind, _reason -> {:error, :session_close_unconfirmed}
  end

  defp close_browser(%{browser_resource: nil, browser_factory: nil} = state) do
    state.backend.close_session(
      state.settings,
      %{"profile_id" => state.session.profile_id},
      state.backend_opts
    )
    |> normalize_close()
  rescue
    _exception -> {:error, :session_close_unconfirmed}
  catch
    _kind, _reason -> {:error, :session_close_unconfirmed}
  end

  defp close_browser(%{browser_resource: nil}), do: :ok

  defp normalize_close(result) do
    case result do
      :ok -> :ok
      {:ok, _result} -> :ok
      {:error, _reason} -> {:error, :session_close_unconfirmed}
      _invalid -> {:error, :session_close_unconfirmed}
    end
  end

  defp reconcile_uncertain_close(state) do
    case close_browser(state) do
      :ok ->
        case release_active_lease(state) do
          :ok -> clear_close_uncertain(state, :closed)
          {:error, _reason} -> persist_status(state, :orphaned)
        end

      {:error, _reason} ->
        mark_close_uncertain(state)
    end
  end

  defp initial_ready_state(state) do
    case SafeBrowser.observe(state.browser) do
      {:ok, observation, browser} ->
        {:ok, %{state | browser: browser} |> update_session(:ready, observation)}

      {:error, _reason, browser} ->
        cleanup_failed_open(%{state | browser: browser})
    end
  end

  defp reconcile_browser(%{browser: %SafeBrowser{}} = state) do
    case SafeBrowser.observe(state.browser) do
      {:ok, observation, browser} ->
        %{state | browser: browser} |> update_session(:ready, observation)

      {:error, _reason, _browser} ->
        state
        |> reset_production_browser()
        |> reconnect_and_observe()
    end
  end

  defp reconcile_browser(state), do: reconnect_and_observe(state)

  defp reconnect_and_observe(state) do
    case ensure_browser(state) do
      {:ok, state} -> fresh_ready_state(state)
      {:error, _reason} -> persist_status(state, :orphaned)
    end
  end

  defp validate_remote_profile(state) do
    case state.backend.profile_status(
           state.settings,
           state.session.profile_id,
           state.backend_opts
         ) do
      {:ok, %{"status" => "running"}} -> :ok
      _not_running_or_unavailable -> {:error, :manager_unavailable}
    end
  rescue
    _exception -> {:error, :manager_unavailable}
  catch
    _kind, _reason -> {:error, :manager_unavailable}
  end

  defp fresh_ready_state(state) do
    case SafeBrowser.observe(state.browser) do
      {:ok, observation, browser} ->
        %{state | browser: browser} |> update_session(:ready, observation)

      {:error, _reason, browser} ->
        %{state | browser: browser} |> persist_status(:orphaned)
    end
  end

  defp browser_reconcile_required?(reason),
    do:
      reason in [
        :action_failed,
        :lease_conflict,
        :navigation_not_allowed,
        :observation_failed,
        :cdp_disconnected,
        :cdp_timeout
      ]

  defp ensure_cdp_supervisor_monitor(%{cdp_supervisor_monitor: ref} = state)
       when is_reference(ref),
       do: state

  defp ensure_cdp_supervisor_monitor(state),
    do: %{state | cdp_supervisor_monitor: monitor_process(state.cdp_supervisor_name)}

  defp clear_client_monitor(%{client_monitor: ref} = state) when is_reference(ref) do
    _ = Process.demonitor(ref, [:flush])
    %{state | client_monitor: nil}
  end

  defp clear_client_monitor(state), do: state

  defp terminate_cdp_client(supervisor, client) do
    DynamicSupervisor.terminate_child(supervisor, client)
  catch
    :exit, _reason -> {:error, :cdp_supervisor_unavailable}
  end

  defp monitor_process(pid) when is_pid(pid), do: Process.monitor(pid)

  defp monitor_process(name) when is_atom(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> Process.monitor(pid)
      nil -> nil
    end
  end

  defp unresolved_action?(state) do
    case Journal.recovery_list(state.journal, :pending_action,
           session_id: state.session.remote_session_id,
           statuses: [:executing, :verifying, :outcome_unknown]
         ) do
      {:ok, []} -> false
      {:ok, [_unresolved | _rest]} -> true
      {:error, _reason} -> true
    end
  catch
    :exit, _reason -> true
  end

  defp cleanup_failed_open(state) do
    case close_browser(state) do
      :ok ->
        release_result =
          ProfileLeaseServer.release(
            state.lease_server,
            state.session.profile_id,
            state.session.lease_id
          )

        status = if release_result == :ok, do: :failed, else: :orphaned
        {:error, persist_status(state, status)}

      {:error, _reason} ->
        {:error, mark_close_uncertain(state)}
    end
  end

  defp reply_manual_handoff(state, operator_id) do
    session = state.session

    case ProfileLeaseServer.manual_handoff(
           state.lease_server,
           session.profile_id,
           session.lease_id,
           operator_id,
           ttl_ms: session.ttl_ms
         ) do
      {:ok, lease} ->
        browser = put_browser_lease(state.browser, lease.lease_id)
        state = %{state | browser: browser} |> persist_lease(lease, :waiting_human)
        {:reply, {:ok, snapshot(state.session)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp acquire_unclaimed_manual(state, operator_id) do
    session = state.session

    case ProfileLeaseServer.acquire(
           state.lease_server,
           session.profile_id,
           :manual,
           operator_id,
           mode: :manual,
           ttl_ms: session.ttl_ms
         ) do
      {:ok, lease} ->
        browser = put_browser_lease(state.browser, lease.lease_id)
        state = %{state | browser: browser} |> persist_lease(lease, :waiting_human)
        {:reply, {:ok, snapshot(state.session)}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp release_manual(state, lease_id, operator_id) do
    released = Map.get(state.session, :manual_released)

    cond do
      released == %{lease_id: lease_id, operator_id: operator_id} ->
        {:reply, {:ok, snapshot(state.session)}, state}

      true ->
        case manual_lease(state) do
          {:ok, %ProfileLease{lease_id: ^lease_id, owner_id: ^operator_id}} ->
            pending = %{lease_id: lease_id, operator_id: operator_id}
            state = persist_manual_release_intent(state, pending)

            case ProfileLeaseServer.release(
                   state.lease_server,
                   state.session.profile_id,
                   lease_id
                 ) do
              :ok ->
                state = persist_manual_released(state, pending)
                {:reply, {:ok, snapshot(state.session)}, state}

              {:error, reason} ->
                {:reply, {:error, reason}, state}
            end

          {:ok, %ProfileLease{owner_type: :manual}} ->
            {:reply, {:error, :operator_identity_mismatch}, state}

          :error ->
            {:reply, {:error, :lease_not_found}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  defp manual_lease(state) do
    case ProfileLeaseServer.get(state.lease_server, state.session.profile_id) do
      {:ok, %ProfileLease{owner_type: :manual} = lease} -> {:ok, lease}
      {:ok, _other} -> {:error, :lease_conflict}
      :error -> :error
    end
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp persist_manual_release_intent(state, pending) do
    session =
      Map.merge(state.session, %{
        manual_release_pending: pending,
        updated_at: DateTime.utc_now()
      })

    persist_session(%{state | session: session})
  end

  defp persist_manual_released(state, released) do
    session =
      Map.merge(state.session, %{
        lease_id: nil,
        status: :waiting_human,
        manual_holder_id: released.operator_id,
        manual_release_pending: nil,
        manual_released: released,
        updated_at: DateTime.utc_now()
      })

    persist_session(%{state | session: session})
  end

  defp recover_manual_release(state) do
    case Map.get(state.session, :manual_release_pending) do
      %{lease_id: lease_id, operator_id: operator_id} = pending ->
        case manual_lease(state) do
          {:ok, %ProfileLease{lease_id: ^lease_id, owner_id: ^operator_id}} ->
            case ProfileLeaseServer.release(
                   state.lease_server,
                   state.session.profile_id,
                   lease_id
                 ) do
              :ok -> persist_manual_released(state, pending)
              {:error, _reason} -> persist_status(state, :orphaned)
            end

          :error ->
            persist_manual_released(state, pending)

          _changed ->
            persist_status(state, :orphaned)
        end

      _none ->
        state
    end
  end

  defp resume_lease(%{session: %{lease_id: nil}} = state) do
    session = state.session

    ProfileLeaseServer.acquire(
      state.lease_server,
      session.profile_id,
      :automation,
      session.remote_session_id,
      mode: session.mode,
      ttl_ms: session.ttl_ms
    )
  end

  defp resume_lease(state) do
    session = state.session

    ProfileLeaseServer.resume(
      state.lease_server,
      session.profile_id,
      session.lease_id,
      owner_id: session.remote_session_id,
      mode: session.mode,
      ttl_ms: session.ttl_ms
    )
  end

  defp release_active_lease(%{session: %{lease_id: nil}}), do: :ok

  defp release_active_lease(state) do
    ProfileLeaseServer.release(
      state.lease_server,
      state.session.profile_id,
      state.session.lease_id
    )
  end

  defp lease_identity(session) do
    cond do
      is_map(Map.get(session, :manual_released)) ->
        %{
          "lease_owner_type" => "released",
          "lease_owner_id" => session.manual_released.operator_id
        }

      session.status == :waiting_human and is_binary(Map.get(session, :manual_holder_id)) ->
        %{
          "lease_owner_type" => "manual",
          "lease_owner_id" => session.manual_holder_id
        }

      is_binary(session.lease_id) ->
        %{
          "lease_owner_type" => "automation",
          "lease_owner_id" => session.remote_session_id
        }

      true ->
        %{}
    end
  end

  defp put_browser_lease(%SafeBrowser{} = browser, lease_id), do: %{browser | lease_id: lease_id}
  defp put_browser_lease(nil, _lease_id), do: nil

  defp persist_lease(state, lease, status) do
    session =
      Map.merge(state.session, %{
        lease_id: lease.lease_id,
        expires_at: lease.expires_at,
        status: status,
        manual_holder_id: if(lease.owner_type == :manual, do: lease.owner_id, else: nil),
        manual_released: nil,
        manual_release_pending: nil,
        updated_at: DateTime.utc_now()
      })

    persist_session(%{state | session: session}) |> schedule_expiry()
  end

  defp persist_status(state, status) do
    session = %{state.session | status: status, updated_at: DateTime.utc_now()}
    persist_session(%{state | session: session})
  end

  defp mark_close_uncertain(state) do
    session = %{
      state.session
      | status: :orphaned,
        close_uncertain: true,
        updated_at: DateTime.utc_now()
    }

    persist_session(%{state | session: session})
  end

  defp clear_close_uncertain(state, status) do
    session = %{
      state.session
      | status: status,
        close_uncertain: false,
        updated_at: DateTime.utc_now()
    }

    persist_session(%{state | session: session})
  end

  defp schedule_expiry(%{session: %{status: status}} = state)
       when status in [:closed, :failed] do
    cancel_expiry(state)
  end

  defp schedule_expiry(state) do
    state = cancel_expiry(state)
    token = make_ref()
    delay = max(DateTime.diff(state.session.expires_at, DateTime.utc_now(), :millisecond), 0)
    timer = Process.send_after(self(), {:session_expired, token}, delay)
    %{state | expiry_timer: timer, expiry_token: token}
  end

  defp cancel_expiry(%{expiry_timer: timer} = state) when is_reference(timer) do
    _ = Process.cancel_timer(timer)
    %{state | expiry_timer: nil, expiry_token: nil}
  end

  defp cancel_expiry(state), do: state

  defp update_session(state, status, observation) do
    session = %{
      state.session
      | status: status,
        observation: observation,
        revision: observation["revision"],
        updated_at: DateTime.utc_now()
    }

    persist_session(%{state | session: session})
  end

  defp sync_browser_observation(%{browser: %SafeBrowser{observation: observation}} = state)
       when is_map(observation) do
    if observation["revision"] > state.session.revision do
      update_session(state, state.session.status, observation)
    else
      state
    end
  end

  defp sync_browser_observation(state), do: state

  defp persist_session(state) do
    :ok =
      Journal.put(
        state.journal,
        :browser_session,
        state.session.remote_session_id,
        state.session
      )

    state
  end
end
