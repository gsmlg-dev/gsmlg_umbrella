defmodule GSMLG.BrowserAgent.WorkflowSupervisor do
  @moduledoc "Supervises durable workflow runners independently from the Commander connection."

  use Supervisor

  alias __MODULE__.Control

  def start_link(opts) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> Supervisor.start_link(__MODULE__, opts)
      name -> Supervisor.start_link(__MODULE__, opts, name: name)
    end
  end

  def start(supervisor \\ __MODULE__, payload, request_meta),
    do: call(supervisor, {:start, payload, request_meta}, :infinity)

  def status(supervisor \\ __MODULE__, central_job_id, remote_execution_id),
    do: call(supervisor, {:status, central_job_id, remote_execution_id})

  def cancel(supervisor \\ __MODULE__, central_job_id, remote_execution_id),
    do: call(supervisor, {:runner_call, central_job_id, remote_execution_id, :cancel}, :infinity)

  def resume(supervisor \\ __MODULE__, central_job_id, remote_execution_id, operator_id),
    do:
      call(
        supervisor,
        {:runner_call, central_job_id, remote_execution_id, {:resume, operator_id}},
        :infinity
      )

  def reconcile(supervisor \\ __MODULE__, central_job_id, remote_execution_id),
    do:
      call(
        supervisor,
        {:runner_call, central_job_id, remote_execution_id, :reconcile},
        :infinity
      )

  @doc false
  def intervene(supervisor \\ __MODULE__, central_job_id, remote_execution_id, reason),
    do:
      call(
        supervisor,
        {:runner_call, central_job_id, remote_execution_id, {:intervene, reason}},
        :infinity
      )

  @doc false
  def step(supervisor \\ __MODULE__, central_job_id, remote_execution_id),
    do: call(supervisor, {:runner_call, central_job_id, remote_execution_id, :step}, :infinity)

  @doc false
  def runner(supervisor \\ __MODULE__, remote_execution_id),
    do: call(supervisor, {:runner, remote_execution_id}, 5_000, nil)

  @impl true
  def init(opts) do
    registry = Keyword.fetch!(opts, :registry_name)
    runners = Keyword.fetch!(opts, :runner_supervisor_name)

    children = [
      {Registry, keys: :unique, name: registry},
      {DynamicSupervisor, strategy: :one_for_one, name: runners},
      %{
        id: Control,
        start:
          {Control, :start_link,
           [
             opts
             |> Keyword.put(:registry_name, registry)
             |> Keyword.put(:runner_supervisor_name, runners)
           ]}
      }
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp call(supervisor, request, timeout \\ 5_000, fallback \\ {:error, :workflow_unavailable}) do
    case control(supervisor) do
      pid when is_pid(pid) -> GenServer.call(pid, request, timeout)
      nil -> fallback
    end
  catch
    :exit, _reason -> fallback
  end

  defp control(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {Control, pid, :worker, _modules} -> pid
      _child -> nil
    end)
  end
end

defmodule GSMLG.BrowserAgent.WorkflowSupervisor.Control do
  @moduledoc false

  use GenServer

  alias GSMLG.BrowserAgent.{Journal, Workflow, WorkflowRunner}

  @start_keys ~w(central_job_id workflow workflow_version profile_id input output_formats requested_by_actor_id)
  @required_output_formats ~w(report.markdown report.json sources.json)
  @optional_output_formats ~w(report.html screenshot.png)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state =
      opts
      |> Keyword.put_new(:max_children, 1)
      |> Keyword.put_new(:state_dir, System.tmp_dir!())
      |> Keyword.put_new(:auto_run, true)
      |> Keyword.put_new(:id_generator, &generate_id/0)
      |> Keyword.put_new(:generation_generator, &generate_generation/0)
      |> Keyword.put_new(:clock, &DateTime.utc_now/0)
      |> Keyword.put_new(:max_observation_bytes, 1_048_576)
      |> Keyword.put_new(:max_artifact_bytes, 104_857_600)
      |> Map.new()

    {:ok, state, {:continue, :recover}}
  end

  @impl true
  def handle_continue(:recover, state) do
    case Journal.workflow_list(state.journal) do
      records when is_list(records) ->
        Enum.each(records, fn {_id, checkpoint} -> recover_checkpoint(state, checkpoint) end)
        {:noreply, Map.put(state, :recovery_error, nil)}

      _error ->
        {:noreply, Map.put(state, :recovery_error, :workflow_recovery_failed)}
    end
  end

  @impl true
  def handle_call({:start, _payload, _meta}, _from, %{recovery_error: reason} = state)
      when not is_nil(reason),
      do: {:reply, {:error, reason}, state}

  def handle_call({:start, payload, meta}, _from, state) do
    reply = start_workflow(state, payload, meta)
    {:reply, reply, state}
  end

  def handle_call({:status, central_id, remote_id}, _from, state) do
    {:reply, resolve_snapshot(state, central_id, remote_id), state}
  end

  def handle_call({:runner_call, central_id, remote_id, request}, _from, state) do
    reply =
      with {:ok, checkpoint} <-
             resolve_checkpoint(state, central_id, remote_id, request == :reconcile) do
        call_or_recover_runner(state, checkpoint, request)
      end

    {:reply, reply, state}
  end

  def handle_call({:runner, remote_id}, _from, state),
    do: {:reply, lookup(state, remote_id), state}

  defp start_workflow(state, payload, meta) do
    with :ok <- validate_deadline(meta, state.clock.()),
         {:ok, validated} <- validate_start(payload, meta),
         {:ok, workflow_module} <- Workflow.module(validated.workflow_id),
         :ok <- validate_input_origins(workflow_module, validated.input),
         {:ok, workflow_state} <- workflow_module.initial_state(validated.input),
         checkpoint <- new_checkpoint(validated, workflow_state, state),
         claim <- Journal.workflow_claim(state.journal, checkpoint, state.max_children) do
      finish_claim(state, claim)
    end
  end

  defp finish_claim(state, {:execute, checkpoint}) do
    with {:ok, pid} <- start_runner(state, checkpoint),
         {:ok, snapshot} <- GenServer.call(pid, :snapshot, :infinity) do
      {:ok, snapshot}
    else
      {:error, _reason} = error -> error
    end
  end

  defp finish_claim(state, {:replay, checkpoint}) do
    case lookup(state, checkpoint.remote_execution_id) do
      pid when is_pid(pid) -> GenServer.call(pid, :snapshot, :infinity)
      nil -> {:ok, WorkflowRunner.snapshot(checkpoint, state.journal)}
    end
  end

  defp finish_claim(_state, {:error, _reason} = error), do: error

  defp resolve_snapshot(state, central_id, remote_id) do
    with {:ok, checkpoint} <- resolve_checkpoint(state, central_id, remote_id, false) do
      case lookup(state, checkpoint.remote_execution_id) do
        pid when is_pid(pid) -> GenServer.call(pid, :snapshot)
        nil -> {:ok, WorkflowRunner.snapshot(checkpoint, state.journal)}
      end
    end
  end

  defp resolve_checkpoint(state, central_id, nil, true) when is_binary(central_id) do
    case Journal.workflow_by_central_job_id(state.journal, central_id) do
      {:ok, checkpoint} -> {:ok, checkpoint}
      :error -> {:error, :workflow_not_found}
    end
  end

  defp resolve_checkpoint(state, central_id, remote_id, _allow_central_only)
       when is_binary(central_id) and is_binary(remote_id) do
    case Journal.workflow_get(state.journal, remote_id) do
      {:ok, %{central_job_id: ^central_id} = checkpoint} -> {:ok, checkpoint}
      {:ok, _mismatch} -> {:error, :workflow_identity_mismatch}
      :error -> {:error, :workflow_not_found}
    end
  end

  defp resolve_checkpoint(_state, _central_id, _remote_id, _allow_central_only),
    do: {:error, :invalid_workflow_request}

  defp call_or_recover_runner(state, checkpoint, request) do
    case lookup(state, checkpoint.remote_execution_id) do
      pid when is_pid(pid) ->
        GenServer.call(pid, request, :infinity)

      nil when checkpoint.status in [:completed, :failed, :cancelled] ->
        terminal_request(request, checkpoint, state)

      nil ->
        with {:ok, claimed} <-
               Journal.workflow_takeover(
                 state.journal,
                 checkpoint.remote_execution_id,
                 state.generation_generator.()
               ),
             {:ok, pid} <- start_runner(state, claimed) do
          GenServer.call(pid, request, :infinity)
        end
    end
  end

  defp terminal_request(request, checkpoint, state) when request in [:cancel, :reconcile],
    do: {:ok, WorkflowRunner.snapshot(checkpoint, state.journal)}

  defp terminal_request(_request, _checkpoint, _state), do: {:error, :workflow_terminal}

  defp recover_checkpoint(_state, %{status: status})
       when status in [:completed, :failed, :cancelled],
       do: :ok

  defp recover_checkpoint(state, checkpoint) do
    with {:ok, claimed} <-
           Journal.workflow_takeover(
             state.journal,
             checkpoint.remote_execution_id,
             state.generation_generator.()
           ) do
      _ = start_runner(state, claimed)
    end
  end

  defp start_runner(state, checkpoint) do
    DynamicSupervisor.start_child(
      state.runner_supervisor_name,
      {WorkflowRunner,
       checkpoint: checkpoint,
       journal: state.journal,
       session_api: state.session_api,
       session_supervisor: state.session_supervisor,
       registry_name: state.registry_name,
       state_dir: state.state_dir,
       max_observation_bytes: state.max_observation_bytes,
       max_artifact_bytes: state.max_artifact_bytes,
       auto_run: state.auto_run,
       clock: state.clock}
    )
  end

  defp lookup(state, remote_id) do
    case Registry.lookup(state.registry_name, remote_id) do
      [{pid, _value}] when is_pid(pid) -> pid
      [] -> nil
    end
  end

  defp validate_start(payload, meta) when is_map(payload) and is_map(meta) do
    keys = Map.keys(payload)
    output_formats = payload["output_formats"]
    workflow_id = "#{payload["workflow"]}/v#{payload["workflow_version"]}"

    with true <- Enum.sort(keys) == Enum.sort(@start_keys),
         true <- bounded_string?(payload["central_job_id"], 256),
         true <- bounded_string?(payload["workflow"], 128),
         true <- is_integer(payload["workflow_version"]) and payload["workflow_version"] > 0,
         true <- bounded_string?(payload["profile_id"], 256),
         true <- is_map(payload["input"]),
         true <-
           Enum.all?(~w(profile_id requested_by_actor_id central_job_id), fn key ->
             not Map.has_key?(payload["input"], key)
           end),
         true <- valid_output_formats?(output_formats),
         true <- bounded_string?(payload["requested_by_actor_id"], 256),
         true <- bounded_string?(meta[:idempotency_key], 256),
         true <- is_binary(meta[:deadline_at]),
         {:ok, _module} <- Workflow.module(workflow_id) do
      {:ok,
       %{
         central_job_id: payload["central_job_id"],
         workflow_id: workflow_id,
         workflow_version: payload["workflow_version"],
         profile_id: payload["profile_id"],
         input: payload["input"],
         output_formats: output_formats,
         requested_by_actor_id: payload["requested_by_actor_id"],
         idempotency_key: meta[:idempotency_key],
         deadline_at: meta[:deadline_at],
         request_fingerprint: fingerprint(payload, meta)
       }}
    else
      _invalid -> {:error, :invalid_workflow_request}
    end
  end

  defp validate_start(_payload, _meta), do: {:error, :invalid_workflow_request}

  defp validate_deadline(%{deadline_at: value}, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, deadline, _offset} ->
        if DateTime.compare(deadline, now) == :gt,
          do: :ok,
          else: {:error, :workflow_deadline_exceeded}

      {:error, _reason} ->
        {:error, :invalid_workflow_request}
    end
  end

  defp validate_deadline(_meta, _now), do: {:error, :invalid_workflow_request}

  defp valid_output_formats?(formats) when is_list(formats) and formats != [] do
    allowed = @required_output_formats ++ @optional_output_formats

    @required_output_formats -- formats == [] and Enum.all?(formats, &(&1 in allowed)) and
      length(formats) == MapSet.size(MapSet.new(formats))
  end

  defp valid_output_formats?(_formats), do: false

  defp bounded_string?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp validate_input_origins(
         GSMLG.BrowserAgent.Workflows.Gemini.YouTubeAnalysis = module,
         %{"youtube_url" => url}
       ) do
    with {:ok, origin} <- GSMLG.BrowserAgent.OriginPolicy.origin(url),
         true <- origin in module.required_origins() do
      :ok
    else
      _invalid -> {:error, :invalid_workflow_request}
    end
  end

  defp validate_input_origins(_module, _input), do: :ok

  defp new_checkpoint(validated, workflow_state, state) do
    %{
      version: 1,
      remote_execution_id: state.id_generator.(),
      central_job_id: validated.central_job_id,
      workflow: validated.workflow_id,
      workflow_version: validated.workflow_version,
      profile_id: validated.profile_id,
      input: validated.input,
      output_formats: validated.output_formats,
      requested_by_actor_id: validated.requested_by_actor_id,
      idempotency_key: validated.idempotency_key,
      request_fingerprint: validated.request_fingerprint,
      deadline_at: validated.deadline_at,
      status: :accepting,
      phase: workflow_state.phase,
      phase_started_at: state.clock.(),
      runner_generation: state.generation_generator.(),
      workflow_state: workflow_state,
      session_id: nil,
      intervention: nil,
      pending_decision: nil,
      fresh_observation_required: false,
      last_observation: nil,
      resumed_by_operator_id: nil,
      action_number: 0,
      result: nil
    }
  end

  defp fingerprint(payload, meta) do
    :crypto.hash(:sha256, :erlang.term_to_binary({payload, meta[:deadline_at]}))
    |> Base.encode16(case: :lower)
  end

  defp generate_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.join(
      [
        Base.encode16(<<a::32>>, case: :lower),
        Base.encode16(<<b::16>>, case: :lower),
        Base.encode16(<<c::16>>, case: :lower),
        Base.encode16(<<d::16>>, case: :lower),
        Base.encode16(<<e::48>>, case: :lower)
      ],
      "-"
    )
  end

  defp generate_generation,
    do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
end
