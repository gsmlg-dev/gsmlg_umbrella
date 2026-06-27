defmodule GSMLG.Scout.Server.JobManager do
  @moduledoc """
  In-memory lifecycle tracker for Scout fetch jobs.
  """

  use GenServer

  alias GSMLG.Scout.Fetch.{Job, Result, RetryPolicy}
  alias GSMLG.Scout.Server.Dispatcher
  alias GSMLG.Scout.Settings

  @topic "gsmlg_scout:jobs"
  @sweep_interval_ms 5_000

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, %{jobs: %{}, waiters: %{}}, name: __MODULE__)
  end

  def submit(params), do: GenServer.call(__MODULE__, {:submit, params})
  def get(job_id), do: GenServer.call(__MODULE__, {:get, job_id})
  def list, do: GenServer.call(__MODULE__, :list)
  def running_count, do: GenServer.call(__MODULE__, :running_count)
  def mark_running(job_id), do: GenServer.cast(__MODULE__, {:running, job_id})
  def handle_result(%Result{} = result), do: GenServer.cast(__MODULE__, {:result, result})

  if Mix.env() == :test do
    def reset do
      GenServer.call(__MODULE__, :reset)
    end
  end

  def fetch_sync(params) do
    timeout_ms = Settings.get()["general"]["request_timeout_ms"]
    GenServer.call(__MODULE__, {:fetch_sync, params}, timeout_ms + 1_000)
  end

  @impl true
  def init(state) do
    schedule_sweep()
    {:ok, state}
  end

  @impl true
  def handle_call({:submit, params}, _from, state) do
    case Job.new(params) do
      {:ok, job} ->
        entry = new_entry(job, "queued")
        state = put_entry(state, entry)
        broadcast(entry)

        dispatch_reply(entry, state)

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:fetch_sync, params}, from, state) do
    case Job.new(params) do
      {:ok, job} ->
        entry = new_entry(job, "queued")
        state = state |> put_entry(entry) |> put_waiter(job.job_id, from)
        broadcast(entry)

        case safe_dispatch(job) do
          :ok ->
            Process.send_after(self(), {:sync_timeout, job.job_id}, job.timeout_ms)
            {:noreply, state}

          {:error, reason} ->
            failed = fail_entry(entry, dispatch_error(reason))
            GenServer.reply(from, {:error, failed.error})
            state = state |> put_entry_and_broadcast(failed) |> delete_waiter(job.job_id)
            {:noreply, state}
        end

      {:error, error} ->
        {:reply, {:error, error}, state}
    end
  end

  def handle_call({:get, job_id}, _from, state) do
    reply =
      state.jobs
      |> Map.get(job_id)
      |> case do
        nil ->
          {:error, %{type: "not_found", message: "fetch job was not found", retryable: false}}

        entry ->
          {:ok, public_entry(entry)}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, state) do
    entries =
      state.jobs
      |> Map.values()
      |> Enum.sort_by(& &1.inserted_at, :desc)
      |> Enum.map(&public_entry/1)

    {:reply, entries, state}
  end

  def handle_call(:running_count, _from, state) do
    count =
      Enum.count(state.jobs, fn {_job_id, entry} ->
        entry.status == "running"
      end)

    {:reply, count, state}
  end

  if Mix.env() == :test do
    def handle_call(:reset, _from, _state) do
      {:reply, :ok, %{jobs: %{}, waiters: %{}}}
    end
  end

  @impl true
  def handle_cast({:running, job_id}, state) do
    {state, _entry} =
      update_entry(state, job_id, fn entry ->
        entry
        |> Map.put(:status, "running")
        |> Map.put(:next_attempt_ms, nil)
        |> touch()
      end)

    {:noreply, state}
  end

  def handle_cast({:result, %Result{} = result}, state) do
    {state, entry} =
      update_entry(state, result.job_id, fn entry ->
        apply_result(entry, result)
      end)

    state =
      if entry && entry.status in ["completed", "failed"] do
        reply_waiter(state, result.job_id, {:ok, result})
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:sync_timeout, job_id}, state) do
    case Map.pop(state.waiters, job_id) do
      {nil, _waiters} ->
        {:noreply, state}

      {from, waiters} ->
        GenServer.reply(
          from,
          {:error, %{type: "timeout", message: "fetch timed out", retryable: true}}
        )

        {:noreply, %{state | waiters: waiters}}
    end
  end

  def handle_info(:sweep, state) do
    now = DateTime.utc_now()
    default_timeout = Settings.get()["fetch"]["default_timeout_ms"]

    state =
      Enum.reduce(state.jobs, state, fn {job_id, entry}, acc ->
        if entry.status in ["queued", "running"] and stale?(entry, now, default_timeout) do
          # Mark as failed due to timeout
          error = %{type: "timeout", message: "job timed out on server", retryable: true}
          result = %Result{job_id: job_id, ok: false, url: entry.job.url, error: error}
          {new_acc, _entry} = update_entry(acc, job_id, fn e -> apply_result(e, result) end)
          new_acc
        else
          acc
        end
      end)

    schedule_sweep()
    {:noreply, state}
  end

  def handle_info({:retry, job_id}, state) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {:noreply, state}

      entry ->
        job = Job.retry(entry.job)
        entry = %{entry | job: job, status: "queued", error: nil} |> touch()
        state = put_entry(state, entry)
        broadcast(entry)

        case safe_dispatch(job) do
          :ok ->
            {:noreply, state}

          {:error, reason} ->
            {state, failed} = fail_and_notify(state, entry, dispatch_error(reason))
            state = reply_waiter(state, job.job_id, {:error, failed.error})
            {:noreply, state}
        end
    end
  end

  defp apply_result(entry, %Result{ok: true} = result) do
    entry
    |> Map.put(:status, "completed")
    |> Map.put(:result, Result.to_map(result))
    |> Map.put(:error, nil)
    |> Map.put(:next_attempt_ms, nil)
    |> touch()
  end

  defp apply_result(entry, %Result{} = result) do
    if RetryPolicy.retryable?(result) and entry.job.attempt < entry.job.max_attempts do
      delay_ms = RetryPolicy.delay_ms(entry.job.attempt, Settings.get())
      Process.send_after(self(), {:retry, entry.job.job_id}, delay_ms)

      entry
      |> Map.put(:status, "retrying")
      |> Map.put(:result, Result.to_map(result))
      |> Map.put(:error, result.error)
      |> Map.put(:next_attempt_ms, delay_ms)
      |> touch()
    else
      entry
      |> Map.put(:status, "failed")
      |> Map.put(:result, Result.to_map(result))
      |> Map.put(:error, result.error)
      |> Map.put(:next_attempt_ms, nil)
      |> touch()
    end
  end

  defp new_entry(%Job{} = job, status) do
    now = timestamp()

    %{
      job: job,
      status: status,
      result: nil,
      error: nil,
      inserted_at: now,
      updated_at: now,
      next_attempt_ms: nil
    }
  end

  defp fail_entry(entry, error) do
    entry
    |> Map.put(:status, "failed")
    |> Map.put(:error, error)
    |> Map.put(:next_attempt_ms, nil)
    |> touch()
  end

  defp update_entry(state, job_id, callback) do
    case Map.get(state.jobs, job_id) do
      nil ->
        {state, nil}

      entry ->
        entry = callback.(entry)
        state = put_entry(state, entry)
        broadcast(entry)
        {state, entry}
    end
  end

  defp put_entry(state, entry) do
    put_in(state, [:jobs, entry.job.job_id], entry)
  end

  defp put_waiter(state, job_id, from), do: put_in(state, [:waiters, job_id], from)

  defp delete_waiter(state, job_id), do: update_in(state.waiters, &Map.delete(&1, job_id))

  defp reply_waiter(state, job_id, reply) do
    case Map.pop(state.waiters, job_id) do
      {nil, _waiters} ->
        state

      {from, waiters} ->
        GenServer.reply(from, reply)
        %{state | waiters: waiters}
    end
  end

  defp dispatch_reply(entry, state) do
    case safe_dispatch(entry.job) do
      :ok ->
        {:reply, {:ok, public_entry(entry)}, state}

      {:error, reason} ->
        {state, failed} = fail_and_notify(state, entry, dispatch_error(reason))
        {:reply, {:error, failed.error}, state}
    end
  end

  defp safe_dispatch(%Job{} = job) do
    Dispatcher.dispatch(job)
  rescue
    exception ->
      {:error, exception}
  catch
    :exit, reason ->
      {:error, {:exit, reason}}

    kind, reason ->
      {:error, {kind, reason}}
  end

  defp dispatch_error(%{type: _type, message: _message, retryable: _retryable} = error), do: error

  defp dispatch_error(reason),
    do: %{type: "dispatch_failed", message: inspect(reason), retryable: true}

  defp fail_and_notify(state, entry, error) do
    failed = fail_entry(entry, error)
    {put_entry_and_broadcast(state, failed), failed}
  end

  defp put_entry_and_broadcast(state, entry) do
    state = put_entry(state, entry)
    broadcast(entry)
    state
  end

  defp touch(entry), do: %{entry | updated_at: timestamp()}

  defp public_entry(entry) do
    %{
      job_id: entry.job.job_id,
      status: entry.status,
      url: entry.job.url,
      timeout_ms: entry.job.timeout_ms,
      priority: entry.job.priority,
      region_hint: entry.job.region_hint,
      attempt: entry.job.attempt,
      max_attempts: entry.job.max_attempts,
      inserted_at: entry.inserted_at,
      updated_at: entry.updated_at,
      next_attempt_ms: entry.next_attempt_ms,
      result: entry.result,
      error: entry.error
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp broadcast(entry) do
    if Process.whereis(GSMLG.PubSub) do
      Phoenix.PubSub.broadcast(GSMLG.PubSub, @topic, {:job_updated, public_entry(entry)})
    end
  end

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @sweep_interval_ms)
  end

  defp stale?(entry, now, default_timeout) do
    timeout_ms = entry.job.timeout_ms || default_timeout
    # We add a buffer of 5 seconds to server-side timeout to allow agent to report back
    max_age_seconds = div(timeout_ms, 1000) + 5

    case DateTime.from_iso8601(entry.updated_at) do
      {:ok, updated_at, _offset} ->
        DateTime.diff(now, updated_at) > max_age_seconds

      _ ->
        false
    end
  end
end
