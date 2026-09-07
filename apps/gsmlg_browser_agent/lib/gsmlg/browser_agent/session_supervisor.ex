defmodule GSMLG.BrowserAgent.SessionSupervisor do
  @moduledoc "Supervises isolated browser session runners and their CDP owners."

  use Supervisor

  alias GSMLG.BrowserAgent.SessionRunner
  alias __MODULE__.Control

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  def open(supervisor \\ __MODULE__, params),
    do: safe_control_call(supervisor, {:open, params}, :infinity)

  @doc false
  def open_workflow(supervisor \\ __MODULE__, params),
    do: safe_control_call(supervisor, {:open_workflow, params}, :infinity)

  def call(supervisor \\ __MODULE__, session_id, request),
    do: safe_control_call(supervisor, {:session_call, session_id, request}, :infinity)

  @doc false
  def runner(supervisor \\ __MODULE__, session_id),
    do: safe_control_call(supervisor, {:runner, session_id}, 5_000, nil)

  @impl true
  def init(opts) do
    settings = Keyword.fetch!(opts, :settings)
    registry = Keyword.fetch!(opts, :registry_name)
    runners = Keyword.fetch!(opts, :runner_supervisor_name)
    cdp = Keyword.fetch!(opts, :cdp_supervisor_name)

    children = [
      {Registry, keys: :unique, name: registry},
      {DynamicSupervisor, strategy: :one_for_one, name: runners},
      {DynamicSupervisor, strategy: :one_for_one, name: cdp},
      %{
        id: Control,
        start:
          {Control, :start_link,
           [
             opts
             |> Keyword.put(:registry_name, registry)
             |> Keyword.put(:runner_supervisor_name, runners)
             |> Keyword.put(:cdp_supervisor_name, cdp)
             |> Keyword.put(:max_children, settings.max_concurrent_sessions)
           ]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp control(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Control, pid, :worker, _modules} -> pid
      _child -> nil
    end)
  end

  defp safe_control_call(supervisor, request, timeout, fallback \\ {:error, :session_unavailable}) do
    case control(supervisor) do
      pid when is_pid(pid) -> GenServer.call(pid, request, timeout)
      nil -> fallback
    end
  catch
    :exit, _reason -> fallback
  end
end

defmodule GSMLG.BrowserAgent.SessionSupervisor.Control do
  @moduledoc false

  use GenServer

  alias GSMLG.BrowserAgent.{Journal, OriginPolicy, ProfileLeaseServer, SessionRunner}

  @open_keys ~w(central_session_id profile_id mode authorized_origins ttl_ms permissions)
  @manual_open_keys @open_keys ++ ["operator_id"]
  @workflow_open_keys @open_keys ++
                        [
                          "remote_execution_id",
                          "artifact_job_id",
                          "required_profile_capabilities"
                        ]
  @workflow_profile_capabilities ["gemini_authenticated"]
  @active_statuses [:opening, :ready, :acting, :waiting, :waiting_human, :closing, :orphaned]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state =
      opts
      |> Keyword.put_new(:id_generator, &generate_id/0)
      |> Map.new()

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case Journal.recovery_list(state.journal, :browser_session, statuses: @active_statuses) do
      {:ok, sessions} ->
        Enum.each(sessions, fn {_id, session} -> _ = start_runner(state, session) end)
        {:noreply, Map.put(state, :recovery_error, nil)}

      {:error, reason} ->
        {:noreply, Map.put(state, :recovery_error, reason)}
    end
  end

  @impl true
  def handle_call({:open, _params}, _from, %{recovery_error: reason} = state)
      when not is_nil(reason),
      do: {:reply, {:error, reason}, state}

  def handle_call({:open, params}, _from, state) do
    required_mode =
      if is_map(params) and params["mode"] == "manual", do: :manual, else: :automation

    open_reply(state, params, required_mode)
  end

  def handle_call({:open_workflow, params}, _from, state) do
    open_reply(state, params, :workflow)
  end

  def handle_call(
        {:session_call, _session_id, _request},
        _from,
        %{recovery_error: reason} = state
      )
      when not is_nil(reason),
      do: {:reply, {:error, reason}, state}

  def handle_call({:session_call, session_id, request}, _from, state) do
    reply =
      case lookup(state, session_id) do
        nil ->
          start_or_lookup_persisted(state, session_id, request)

        pid ->
          case safe_call(pid, request) do
            {:error, :session_unavailable} ->
              start_or_lookup_persisted(state, session_id, request)

            reply ->
              reply
          end
      end

    {:reply, reply, state}
  end

  def handle_call({:runner, session_id}, _from, state) do
    {:reply, lookup(state, session_id), state}
  end

  defp open_reply(state, params, required_mode) do
    reply =
      with {:ok, validated} <- validate_open(params, state, required_mode),
           :none <- existing_central_session(state, validated),
           :ok <- validate_profile_capabilities(validated, required_mode),
           :ok <- validate_profile_available(state, validated.profile_id),
           :ok <- validate_capacity(state),
           session <- new_session(validated, state),
           {:ok, pid} <- start_runner(state, session) do
        GenServer.call(pid, :snapshot, :infinity)
      else
        {:existing, snapshot} -> {:ok, snapshot}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  defp validate_open(params, state, required_mode) when is_map(params) do
    allowed_keys =
      case required_mode do
        :workflow -> @workflow_open_keys
        :manual -> @manual_open_keys
        :automation -> @open_keys
      end

    with true <-
           Enum.sort(Map.keys(params)) ==
             Enum.sort(Enum.filter(allowed_keys, &Map.has_key?(params, &1))),
         {:ok, central_id} <- required_id(params["central_session_id"]),
         {:ok, profile_id} <- required_id(params["profile_id"]),
         {:ok, ^required_mode} <- mode(params["mode"]),
         {:ok, requested_operator_id} <- requested_operator_id(params, required_mode),
         {:ok, remote_id} <- workflow_remote_id(params, required_mode, central_id),
         {:ok, artifact_job_id} <- workflow_artifact_job_id(params, required_mode),
         {:ok, required_capabilities} <-
           workflow_profile_capabilities(params, required_mode),
         {:ok, ttl_ms} <- ttl(params["ttl_ms"]),
         {:ok, permissions} <- permissions(Map.get(params, "permissions", %{})),
         {:ok, policy} <-
           origin_policy(params["authorized_origins"], state.settings.allowed_origins) do
      {:ok,
       %{
         central_session_id: central_id,
         profile_id: profile_id,
         mode: required_mode,
         requested_operator_id: requested_operator_id,
         remote_session_id: remote_id,
         artifact_job_id: artifact_job_id,
         artifact_remote_execution_id: remote_id,
         required_profile_capabilities: required_capabilities,
         ttl_ms: ttl_ms,
         permissions: permissions,
         authorized_origins: params["authorized_origins"],
         origin_policy: policy
       }}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :invalid_session_request}
    end
  end

  defp validate_open(_params, _state, _required_mode), do: {:error, :invalid_session_request}

  defp required_id(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_session_request}
  end

  defp required_id(_value), do: {:error, :invalid_session_request}

  defp mode("automation"), do: {:ok, :automation}
  defp mode("manual"), do: {:ok, :manual}
  defp mode("workflow"), do: {:ok, :workflow}
  defp mode(_mode), do: {:error, :invalid_session_request}

  defp requested_operator_id(%{"operator_id" => operator_id}, :manual),
    do: required_id(operator_id)

  defp requested_operator_id(_params, required_mode)
       when required_mode in [:automation, :workflow],
       do: {:ok, nil}

  defp requested_operator_id(_params, :manual), do: {:error, :invalid_session_request}

  defp workflow_remote_id(_params, required_mode, _central_id)
       when required_mode in [:automation, :manual],
       do: {:ok, nil}

  defp workflow_remote_id(%{"remote_execution_id" => remote_id}, :workflow, central_id)
       when remote_id == central_id,
       do: required_id(remote_id)

  defp workflow_remote_id(_params, :workflow, _central_id),
    do: {:error, :invalid_session_request}

  defp workflow_artifact_job_id(_params, required_mode)
       when required_mode in [:automation, :manual],
       do: {:ok, nil}

  defp workflow_artifact_job_id(%{"artifact_job_id" => job_id}, :workflow),
    do: required_id(job_id)

  defp workflow_artifact_job_id(_params, :workflow), do: {:error, :invalid_session_request}

  defp workflow_profile_capabilities(_params, required_mode)
       when required_mode in [:automation, :manual],
       do: {:ok, []}

  defp workflow_profile_capabilities(
         %{"required_profile_capabilities" => capabilities},
         :workflow
       )
       when is_list(capabilities) and capabilities != [] do
    if Enum.sort(capabilities) == Enum.sort(@workflow_profile_capabilities),
      do: {:ok, capabilities},
      else: {:error, :profile_capability_mismatch}
  end

  defp workflow_profile_capabilities(_params, :workflow),
    do: {:error, :profile_capability_mismatch}

  defp validate_profile_capabilities(_request, required_mode)
       when required_mode in [:automation, :manual],
       do: :ok

  defp validate_profile_capabilities(request, :workflow) do
    if request.required_profile_capabilities == @workflow_profile_capabilities,
      do: :ok,
      else: {:error, :profile_capability_mismatch}
  end

  defp ttl(value) when is_integer(value) and value > 0 and value <= 86_400_000, do: {:ok, value}
  defp ttl(_value), do: {:error, :invalid_session_request}

  defp permissions(value) when is_map(value) do
    if Enum.all?(Map.keys(value), &(&1 in ["screenshot", "download"])) and
         Enum.all?(Map.values(value), &is_boolean/1) do
      {:ok,
       %{
         screenshot: Map.get(value, "screenshot", false),
         download: Map.get(value, "download", false)
       }}
    else
      {:error, :invalid_session_request}
    end
  end

  defp permissions(_value), do: {:error, :invalid_session_request}

  defp origin_policy(origins, allowed) when is_list(origins) and origins != [] do
    with {:ok, requested} <- normalized_origins(origins),
         {:ok, configured} <- normalized_origins(allowed),
         true <- MapSet.subset?(MapSet.new(requested), MapSet.new(configured)),
         {:ok, policy} <- OriginPolicy.new(allowed_origins: requested) do
      {:ok, policy}
    else
      _invalid -> {:error, :invalid_origin_policy}
    end
  end

  defp origin_policy(_origins, _allowed), do: {:error, :invalid_origin_policy}

  defp normalized_origins(origins) do
    Enum.reduce_while(origins, {:ok, []}, fn value, {:ok, acc} ->
      case OriginPolicy.origin(value) do
        {:ok, origin} -> {:cont, {:ok, [origin | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_origin_policy}}
      end
    end)
  end

  defp existing_central_session(state, validated) do
    case Journal.browser_session_by_central_id(state.journal, validated.central_session_id) do
      {:ok, existing} ->
        cond do
          not same_request?(existing, validated) ->
            {:error, :central_session_id_collision}

          existing.status == :failed or
              (existing.status == :orphaned and is_nil(existing.observation)) ->
            {:error, :session_open_failed}

          true ->
            {:existing, SessionRunner.snapshot(existing)}
        end

      :error ->
        :none

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp same_request?(session, request) do
    session.profile_id == request.profile_id and session.mode == request.mode and
      session.authorized_origins == request.authorized_origins and
      session.artifact_job_id == request.artifact_job_id and
      Map.get(session, :requested_operator_id) == request.requested_operator_id and
      session.ttl_ms == request.ttl_ms and session.permissions == request.permissions
  end

  defp validate_capacity(state) do
    active =
      state.runner_supervisor_name
      |> DynamicSupervisor.which_children()
      |> Enum.count(fn {_id, pid, _type, _modules} -> is_pid(pid) end)

    if active < state.max_children, do: :ok, else: {:error, :session_capacity_exceeded}
  end

  defp validate_profile_available(state, profile_id) do
    case ProfileLeaseServer.get(state.lease_server, profile_id) do
      :error -> :ok
      {:ok, _lease} -> {:error, :profile_busy}
    end
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp new_session(request, state) do
    now = DateTime.utc_now()

    request
    |> Map.drop([:origin_policy])
    |> Map.merge(%{
      remote_session_id: request.remote_session_id || state.id_generator.(),
      lease_id: nil,
      status: :opening,
      revision: 0,
      observation: nil,
      created_at: now,
      updated_at: now,
      close_uncertain: false,
      manual_holder_id: nil,
      manual_release_pending: nil,
      manual_released: nil,
      expires_at: DateTime.add(now, request.ttl_ms, :millisecond)
    })
    |> Map.put(:origin_policy, request.origin_policy)
  end

  defp start_runner(state, session) do
    opts = [
      session: session,
      registry_name: state.registry_name,
      journal: state.journal,
      lease_server: state.lease_server,
      settings: state.settings,
      browser_factory: state[:browser_factory],
      browser_closer: state[:browser_closer],
      backend: state[:backend],
      backend_opts: state[:backend_opts] || [],
      cdp_client_opts: state[:cdp_client_opts] || [],
      cdp_supervisor_name: state.cdp_supervisor_name
    ]

    case DynamicSupervisor.start_child(state.runner_supervisor_name, {SessionRunner, opts}) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, :session_capacity_exceeded}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, _reason} -> {:error, :session_open_failed}
    end
  end

  defp lookup(state, session_id) do
    case Registry.lookup(state.registry_name, session_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  defp start_or_lookup_persisted(state, session_id, request) do
    case Journal.get(state.journal, :browser_session, session_id) do
      {:ok, %{status: :closed} = session} when request == :close ->
        {:ok, SessionRunner.snapshot(session)}

      {:ok, %{status: status}} when status in [:closed, :failed] ->
        {:error, :session_not_ready}

      {:ok, session} ->
        case start_runner(state, session) do
          {:ok, pid} -> safe_call(pid, request)
          {:error, reason} -> {:error, reason}
        end

      :error ->
        {:error, :session_not_found}
    end
  end

  defp safe_call(pid, request) do
    GenServer.call(pid, request, :infinity)
  catch
    :exit, _reason -> {:error, :session_unavailable}
  end

  defp generate_id, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
