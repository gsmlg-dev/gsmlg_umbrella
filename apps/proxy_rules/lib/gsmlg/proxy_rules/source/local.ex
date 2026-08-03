defmodule GSMLG.ProxyRules.Source.Local do
  @moduledoc """
  Watches and periodically reconciles the two local proxy-rule source files.

  Local inputs are bounded to 8 MiB and descriptor reads are bounded to 250 ms.
  This keeps special files and unexpectedly large inputs from wedging the source
  service or growing it without limit.
  """

  use GenServer

  alias GSMLG.ProxyRules.{
    Configuration,
    LocalProxyBatch,
    LocalProxyWriter,
    SourceSnapshot,
    Store,
    Telemetry
  }

  alias GSMLG.ProxyRules.Parser.Local, as: LocalParser

  @max_source_bytes 8 * 1024 * 1024
  @read_timeout 250
  @writer_errors [
    :permission_denied,
    :open_failed,
    :write_failed,
    :sync_failed,
    :close_failed,
    :mode_failed,
    :rename_failed,
    :invalid_target,
    :target_probe_failed
  ]

  @type failure ::
          :not_found
          | :permission_denied
          | :invalid_utf8
          | :invalid_replacement
          | :body_too_large
          | :read_failed
  @type durability :: :confirmed | :unknown
  @type reconciliation :: :ok | {:error, failure()}
  @type mutation_result :: %{
          added_domains: [binary()],
          added_count: non_neg_integer(),
          duplicate_count: non_neg_integer(),
          durability: durability(),
          reconciliation: reconciliation()
        }
  @type mutation_failure ::
          :not_available | LocalProxyBatch.error_reason() | LocalProxyWriter.error_reason()

  @doc false
  @spec max_source_bytes() :: pos_integer()
  def max_source_bytes, do: @max_source_bytes

  @doc false
  @spec read_timeout() :: pos_integer()
  def read_timeout, do: @read_timeout

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with :ok <- validate_options(options),
         {:ok, targets} <- canonical_targets(Keyword.fetch!(options, :config)) do
      {gen_options, init_options} = Keyword.split(options, [:name])
      GenServer.start_link(__MODULE__, Keyword.put(init_options, :targets, targets), gen_options)
    end
  end

  def start_link(_options), do: {:error, {:invalid_option, :options}}

  @spec snapshots(GenServer.server()) :: %{proxy: SourceSnapshot.t(), direct: SourceSnapshot.t()}
  def snapshots(server), do: GenServer.call(server, :snapshots)

  @spec reconcile(GenServer.server()) :: :ok | {:error, :watcher_failed}
  def reconcile(server), do: GenServer.call(server, :reconcile)

  @spec add_proxy_domains(GenServer.server(), binary()) ::
          {:ok, mutation_result()} | {:error, mutation_failure()}
  def add_proxy_domains(server, text) when is_binary(text),
    do: GenServer.call(server, {:add_proxy_domains, text}, 30_000)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      config: Keyword.fetch!(options, :config),
      targets: Keyword.fetch!(options, :targets),
      notify: Keyword.fetch!(options, :notify),
      file_system: Keyword.get(options, :file_system, FileSystem),
      file_system_options: Keyword.get(options, :file_system_options, []),
      scheduler: Keyword.get(options, :scheduler, &default_schedule/3),
      cancel_timer: Keyword.get(options, :cancel_timer, &Process.cancel_timer/1),
      now: Keyword.get(options, :now, &DateTime.utc_now/0),
      writer: Keyword.get(options, :writer, &LocalProxyWriter.write/2),
      watcher: nil,
      watch_directories: [],
      debounce_timer: nil,
      periodic_timer: nil,
      entries: %{proxy: new_entry(), direct: new_entry()}
    }

    {:ok, state, {:continue, :watch_and_reconcile}}
  end

  @impl true
  def handle_continue(:watch_and_reconcile, state) do
    case refresh_watcher(state) do
      {:ok, state} -> {:noreply, state |> reconcile_sources() |> schedule_periodic()}
      {:error, reason} -> stop_for_watcher(reason, state)
    end
  end

  @impl true
  def handle_call(:snapshots, _from, state), do: {:reply, public_snapshots(state.entries), state}

  def handle_call(:reconcile, _from, state) do
    case refresh_watcher(state) do
      {:ok, state} ->
        {:reply, :ok, reconcile_sources(state)}

      {:error, reason} ->
        emit_watcher_failure()
        {:stop, {:watcher_failed, reason}, {:error, :watcher_failed}, state}
    end
  end

  def handle_call({:add_proxy_domains, text}, _from, state) do
    entry = state.entries.proxy
    target = state.targets.proxy

    with :ok <- writable_snapshot?(entry),
         {:ok, result} <-
           LocalProxyBatch.prepare(entry.snapshot.content, text, max_bytes: @max_source_bytes),
         {:ok, durability} <- call_writer(state.writer, target.path, result.content) do
      reconciled = reconcile_sources(state)
      reconciliation = reconciliation_result(result.content, reconciled.entries.proxy)

      summary =
        result
        |> Map.take([:added_domains, :added_count, :duplicate_count])
        |> Map.put(:durability, durability)
        |> Map.put(:reconciliation, reconciliation)

      {:reply, {:ok, summary}, reconciled}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:file_event, watcher, {path, _events}}, %{watcher: watcher} = state)
      when is_binary(path) do
    if relevant_path?(path, state) do
      {:noreply, schedule_debounce(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state),
    do: stop_for_watcher(:unexpected_stop, state)

  def handle_info({:debounced_reconcile, token}, %{debounce_timer: %{token: token}} = state) do
    state = %{state | debounce_timer: nil}

    case refresh_watcher(state) do
      {:ok, state} -> {:noreply, reconcile_sources(state)}
      {:error, reason} -> stop_for_watcher(reason, state)
    end
  end

  def handle_info({:debounced_reconcile, _stale_token}, state), do: {:noreply, state}

  def handle_info({:periodic_reconcile, token}, %{periodic_timer: %{token: token}} = state) do
    state = %{state | periodic_timer: nil}

    case refresh_watcher(state) do
      {:ok, state} -> {:noreply, state |> reconcile_sources() |> schedule_periodic()}
      {:error, reason} -> stop_for_watcher(reason, state)
    end
  end

  def handle_info({:periodic_reconcile, _stale_token}, state), do: {:noreply, state}

  def handle_info({:EXIT, watcher, reason}, %{watcher: watcher} = state),
    do: stop_for_watcher(bounded_exit_reason(reason), state)

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.debounce_timer, state.cancel_timer)
    cancel_timer(state.periodic_timer, state.cancel_timer)
    stop_watcher(state.watcher)
    :ok
  end

  defp new_entry,
    do: %{snapshot: nil, has_valid_snapshot: false, last_failure: nil}

  defp validate_options(options) do
    validators = [
      {:config, &match?(%Configuration{}, &1)},
      {:notify, &(is_pid(&1) or is_atom(&1))},
      {:file_system, &valid_file_system?/1},
      {:file_system_options, &Keyword.keyword?/1},
      {:scheduler, &is_function(&1, 3)},
      {:cancel_timer, &is_function(&1, 1)},
      {:now, &is_function(&1, 0)},
      {:writer, &is_function(&1, 2)}
    ]

    defaults = %{
      file_system: FileSystem,
      file_system_options: [],
      scheduler: &default_schedule/3,
      cancel_timer: &Process.cancel_timer/1,
      now: &DateTime.utc_now/0,
      writer: &LocalProxyWriter.write/2
    }

    Enum.reduce_while(validators, :ok, fn {key, validator}, :ok ->
      value = Keyword.get(options, key, Map.get(defaults, key, :missing))

      if validator.(value),
        do: {:cont, :ok},
        else: {:halt, {:error, {:invalid_option, key}}}
    end)
  end

  defp canonical_targets(config) do
    with {:ok, proxy} <- canonical_path(config.local_proxy_list_path),
         {:ok, direct} <- canonical_path(config.local_direct_list_path) do
      if proxy == direct do
        {:error, {:invalid_option, :local_source_paths}}
      else
        {:ok,
         %{
           proxy: %{kind: :local_proxy, action: :proxy, path: proxy},
           direct: %{kind: :local_direct, action: :direct, path: direct}
         }}
      end
    else
      :error -> {:error, {:invalid_option, :local_source_paths}}
    end
  end

  defp canonical_path(path) when is_binary(path) and byte_size(path) > 0,
    do: {:ok, Path.expand(path)}

  defp canonical_path(_path), do: :error

  defp valid_file_system?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) and
      function_exported?(module, :subscribe, 1)
  end

  defp valid_file_system?(_module), do: false

  defp writable_snapshot?(%{
         has_valid_snapshot: true,
         snapshot: %SourceSnapshot{availability: availability}
       })
       when availability in [:ready, :missing],
       do: :ok

  defp writable_snapshot?(_entry), do: {:error, :not_available}

  defp call_writer(writer, path, content) do
    case writer.(path, content) do
      :ok -> {:ok, :confirmed}
      {:ok, :durability_unknown} -> {:ok, :unknown}
      {:error, reason} when reason in @writer_errors -> {:error, reason}
      _unexpected -> {:error, :write_failed}
    end
  rescue
    _error -> {:error, :write_failed}
  catch
    _kind, _reason -> {:error, :write_failed}
  end

  defp reconciliation_result(expected_content, entry) do
    expected_hash = sha256(expected_content)

    case entry do
      %{snapshot: %SourceSnapshot{content_sha256: ^expected_hash}, last_failure: nil} -> :ok
      %{last_failure: reason} when is_atom(reason) -> {:error, reason}
      _entry -> {:error, :read_failed}
    end
  end

  defp refresh_watcher(state) do
    directories = desired_watch_directories(state.targets)

    if state.watcher && state.watch_directories == directories do
      {:ok, state}
    else
      replace_watcher(directories, state)
    end
  end

  defp desired_watch_directories(targets) do
    targets
    |> Map.values()
    |> Enum.map(&nearest_existing_ancestor(Path.dirname(&1.path)))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp nearest_existing_ancestor(path) do
    if File.dir?(path) do
      path
    else
      parent = Path.dirname(path)
      if parent == path, do: path, else: nearest_existing_ancestor(parent)
    end
  end

  defp replace_watcher(directories, state) do
    watcher_options = Keyword.put(state.file_system_options, :dirs, directories)

    case state.file_system.start_link(watcher_options) do
      {:ok, watcher} when is_pid(watcher) ->
        case subscribe_watcher(state.file_system, watcher) do
          :ok ->
            stop_watcher(state.watcher)
            {:ok, %{state | watcher: watcher, watch_directories: directories}}

          _failure ->
            stop_watcher(watcher)
            {:error, :subscribe_failed}
        end

      _failure ->
        {:error, :start_failed}
    end
  rescue
    _error -> {:error, :start_failed}
  catch
    _kind, _reason -> {:error, :start_failed}
  end

  defp subscribe_watcher(file_system, watcher) do
    file_system.subscribe(watcher)
  rescue
    _error -> :error
  catch
    _kind, _reason -> :error
  end

  defp stop_watcher(nil), do: :ok

  defp stop_watcher(watcher) when is_pid(watcher) do
    Process.unlink(watcher)

    if Process.alive?(watcher) do
      try do
        GenServer.stop(watcher, :normal, 1_000)
      catch
        :exit, _reason -> :ok
      end
    end

    :ok
  end

  defp reconcile_sources(state) do
    state.targets
    |> Enum.map(fn {slot, target} ->
      {slot, Task.async(fn -> descriptor_read(target.path) end)}
    end)
    |> await_reads()
    |> Enum.map(fn {slot, result} ->
      target = Map.fetch!(state.targets, slot)

      {slot,
       validate_read_result(
         result,
         target.action,
         target.kind,
         state.config.unsupported_rule_sample_limit
       )}
    end)
    |> Enum.reduce(state, fn {slot, result}, current ->
      reconcile_result(slot, result, current)
    end)
  end

  defp await_reads(slot_tasks) do
    tasks = Enum.map(slot_tasks, &elem(&1, 1))
    slots = Map.new(slot_tasks, fn {slot, task} -> {task.ref, slot} end)

    tasks
    |> Task.yield_many(@read_timeout)
    |> Enum.map(fn
      {task, {:ok, result}} ->
        {Map.fetch!(slots, task.ref), result}

      {task, _exit_or_timeout} ->
        _ = Task.shutdown(task, :brutal_kill)
        {Map.fetch!(slots, task.ref), {:error, :read_failed}}
    end)
  end

  defp validate_read_result(result, action, kind, sample_limit) do
    case result do
      {:ok, bytes} -> validate_content(bytes, action, kind, sample_limit)
      {:error, :enoent} -> {:ok, "", :missing}
      {:error, reason} -> {:error, file_failure(reason)}
    end
  rescue
    _error -> {:error, :invalid_replacement}
  catch
    _kind, _reason -> {:error, :invalid_replacement}
  end

  defp descriptor_read(path) do
    with {:ok, descriptor} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      try do
        descriptor_contents(descriptor)
      after
        :file.close(descriptor)
      end
    end
  end

  defp descriptor_contents(descriptor) do
    with {:ok, info_record} <- :file.read_file_info(descriptor),
         %File.Stat{type: :regular, size: size} <- File.Stat.from_record(info_record),
         true <- size <= @max_source_bytes,
         {:ok, bytes} <- read_bytes(descriptor),
         true <- byte_size(bytes) <= @max_source_bytes do
      {:ok, bytes}
    else
      %File.Stat{} -> {:error, :nonregular}
      false -> {:error, :body_too_large}
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, :read_failed}
    end
  end

  defp read_bytes(descriptor) do
    case :file.read(descriptor, @max_source_bytes + 1) do
      {:ok, bytes} -> {:ok, bytes}
      :eof -> {:ok, ""}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_content(bytes, action, kind, sample_limit) do
    if String.valid?(bytes) do
      content = normalize(bytes)

      if valid_replacement?(content, action, kind, sample_limit),
        do: {:ok, content, :ready},
        else: {:error, :invalid_replacement}
    else
      {:error, :invalid_utf8}
    end
  end

  defp normalize(bytes) do
    content =
      bytes
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.split("\n", trim: false)
      |> Enum.map(&Regex.replace(~r/[ \t]+$/u, &1, ""))
      |> drop_trailing_empty_lines()
      |> Enum.join("\n")

    if content == "", do: "", else: content <> "\n"
  end

  defp drop_trailing_empty_lines(lines) do
    lines
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
  end

  defp valid_replacement?("", _action, _kind, _sample_limit), do: true

  defp valid_replacement?(content, action, kind, sample_limit) do
    result = LocalParser.parse(content, action, kind, sample_limit)
    result.counts.accepted > 0 or result.counts.invalid == 0
  end

  defp reconcile_result(slot, {:ok, content, availability}, state) do
    target = Map.fetch!(state.targets, slot)
    entry = Map.fetch!(state.entries, slot)
    accept_source(slot, target, content, availability, entry, state)
  end

  defp reconcile_result(slot, {:error, reason}, state) do
    target = Map.fetch!(state.targets, slot)
    entry = Map.fetch!(state.entries, slot)
    fail_source(slot, target, reason, entry, state)
  end

  defp accept_source(slot, target, content, availability, entry, state) do
    observed_at = state.now.()
    hash = sha256(content)
    {line_count, line_checkpoints} = SourceSnapshot.line_metadata(content)

    snapshot = %SourceSnapshot{
      kind: target.kind,
      content: content,
      content_sha256: hash,
      observed_at: observed_at,
      line_count: line_count,
      line_checkpoints: line_checkpoints,
      metadata: %{
        path: target.path,
        last_success_at: if(availability == :ready, do: observed_at, else: nil)
      },
      availability: availability
    }

    cond do
      not entry.has_valid_snapshot ->
        source_changed(target.kind, snapshot, state)
        put_entry(state, slot, %{snapshot: snapshot, has_valid_snapshot: true, last_failure: nil})

      availability == :missing and entry.snapshot.availability == :missing ->
        put_entry(state, slot, %{entry | snapshot: snapshot, last_failure: nil})

      availability == :missing ->
        fail_source(slot, target, :not_found, entry, state)

      entry.snapshot.content_sha256 != hash ->
        source_changed(target.kind, snapshot, state)
        put_entry(state, slot, %{entry | snapshot: snapshot, last_failure: nil})

      entry.snapshot.availability != :ready ->
        notify_fresh(state.notify, target.kind, observed_at)
        put_entry(state, slot, %{entry | snapshot: snapshot, last_failure: nil})

      true ->
        notify_fresh(state.notify, target.kind, observed_at)
        put_entry(state, slot, %{entry | snapshot: snapshot, last_failure: nil})
    end
  end

  defp source_changed(kind, snapshot, state) do
    _ = Telemetry.emit([:local, :source, :change], %{}, %{source: kind})
    _revision = Store.advance_source_revision(Store)
    notify(state.notify, {:proxy_rules_source, kind, snapshot})
  end

  defp fail_source(slot, target, reason, entry, state) do
    snapshot = stale_snapshot(target, entry.snapshot, state.now.())
    if entry.last_failure != reason, do: notify_failure(target.kind, reason, snapshot, state)

    put_entry(state, slot, %{
      entry
      | snapshot: snapshot,
        last_failure: reason
    })
  end

  defp stale_snapshot(target, nil, observed_at) do
    %SourceSnapshot{
      kind: target.kind,
      content: "",
      content_sha256: sha256(""),
      observed_at: observed_at,
      line_count: 0,
      metadata: %{path: target.path, last_success_at: nil},
      availability: :stale
    }
  end

  defp stale_snapshot(_target, snapshot, observed_at),
    do: %{snapshot | availability: :stale, observed_at: observed_at}

  defp notify_fresh(destination, kind, observed_at) do
    notify(
      destination,
      {:proxy_rules_source_fresh, kind,
       %{availability: :ready, observed_at: observed_at, last_success_at: observed_at}}
    )
  end

  defp notify_failure(kind, reason, snapshot, state) do
    _ =
      Telemetry.emit([:local, :reconciliation, :failure], %{}, %{
        source: kind,
        failure_category: telemetry_failure(reason)
      })

    _revision = Store.advance_source_revision(Store)

    timing = %{
      availability: :stale,
      observed_at: snapshot.observed_at,
      last_success_at: Map.get(snapshot.metadata, :last_success_at)
    }

    notify(state.notify, {:proxy_rules_source_status, kind, :stale, reason, timing})
  end

  defp telemetry_failure(reason)
       when reason in [:not_found, :permission_denied, :invalid_utf8, :body_too_large],
       do: reason

  defp telemetry_failure(_reason), do: :read_failed

  defp stop_for_watcher(reason, state) do
    emit_watcher_failure()
    {:stop, {:watcher_failed, reason}, state}
  end

  defp emit_watcher_failure do
    Enum.each([:local_proxy, :local_direct], fn source ->
      _ =
        Telemetry.emit([:local, :reconciliation, :failure], %{}, %{
          source: source,
          failure_category: :watcher_failed
        })
    end)
  end

  defp put_entry(state, slot, entry), do: put_in(state, [:entries, slot], entry)

  defp public_snapshots(entries) do
    %{proxy: entries.proxy.snapshot, direct: entries.direct.snapshot}
  end

  defp relevant_path?(path, state) do
    event_paths =
      if Path.type(path) == :absolute do
        [Path.expand(path)]
      else
        Enum.map(state.watch_directories, &Path.expand(path, &1))
      end

    Enum.any?(event_paths, fn event_path ->
      Enum.any?(state.targets, fn {_slot, target} -> ancestor_of?(event_path, target.path) end)
    end)
  end

  defp ancestor_of?(candidate, target) do
    candidate_parts = Path.split(candidate)
    target_parts = Path.split(target)
    Enum.take(target_parts, length(candidate_parts)) == candidate_parts
  end

  defp schedule_debounce(state) do
    cancel_timer(state.debounce_timer, state.cancel_timer)
    token = make_ref()

    reference =
      state.scheduler.(self(), {:debounced_reconcile, token}, state.config.local_watch_debounce)

    %{state | debounce_timer: %{ref: reference, token: token}}
  end

  defp schedule_periodic(state) do
    cancel_timer(state.periodic_timer, state.cancel_timer)
    token = make_ref()

    reference =
      state.scheduler.(
        self(),
        {:periodic_reconcile, token},
        state.config.local_reconciliation_interval
      )

    %{state | periodic_timer: %{ref: reference, token: token}}
  end

  defp cancel_timer(nil, _cancel), do: :ok
  defp cancel_timer(%{ref: reference}, cancel), do: cancel.(reference)

  defp default_schedule(server, message, delay), do: Process.send_after(server, message, delay)

  defp file_failure(reason) when reason in [:eacces, :eperm], do: :permission_denied
  defp file_failure(:enoent), do: :enoent
  defp file_failure(:body_too_large), do: :body_too_large
  defp file_failure(_reason), do: :read_failed

  defp bounded_exit_reason(reason) when reason in [:normal, :shutdown, :killed], do: reason
  defp bounded_exit_reason(_reason), do: :unexpected_exit

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp notify(destination, message) when is_pid(destination), do: send(destination, message)

  defp notify(destination, message) when is_atom(destination) do
    if Process.whereis(destination), do: send(destination, message), else: message
  end
end
