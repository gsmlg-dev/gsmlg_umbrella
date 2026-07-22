defmodule GSMLG.ProxyRules.Source.Local do
  @moduledoc """
  Watches and periodically reconciles the two local proxy-rule source files.
  """

  use GenServer

  alias GSMLG.ProxyRules.{Configuration, SourceSnapshot, Telemetry}
  alias GSMLG.ProxyRules.Parser.Local, as: LocalParser

  @type failure ::
          :not_found | :permission_denied | :invalid_utf8 | :invalid_replacement | :read_failed

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    with :ok <- validate_options(options) do
      {gen_options, init_options} = Keyword.split(options, [:name])
      GenServer.start_link(__MODULE__, init_options, gen_options)
    end
  end

  def start_link(_options), do: {:error, {:invalid_option, :options}}

  @spec snapshots(GenServer.server()) :: %{proxy: SourceSnapshot.t(), direct: SourceSnapshot.t()}
  def snapshots(server), do: GenServer.call(server, :snapshots)

  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server), do: GenServer.call(server, :reconcile)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(options, :config)

    state = %{
      config: config,
      notify: Keyword.fetch!(options, :notify),
      file_system: Keyword.get(options, :file_system, FileSystem),
      file_system_options: Keyword.get(options, :file_system_options, []),
      scheduler: Keyword.get(options, :scheduler, &default_schedule/3),
      cancel_timer: Keyword.get(options, :cancel_timer, &Process.cancel_timer/1),
      now: Keyword.get(options, :now, &DateTime.utc_now/0),
      watcher: nil,
      debounce_timer: nil,
      periodic_timer: nil,
      sources: %{proxy: nil, direct: nil}
    }

    {:ok, state, {:continue, :reconcile_and_watch}}
  end

  @impl true
  def handle_continue(:reconcile_and_watch, state) do
    state = reconcile_sources(state)

    case start_watcher(state) do
      {:ok, state} -> {:noreply, schedule_periodic(state)}
      {:error, reason} -> stop_for_watcher(reason, state)
    end
  end

  @impl true
  def handle_call(:snapshots, _from, state), do: {:reply, public_snapshots(state.sources), state}

  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, reconcile_sources(state)}
  end

  @impl true
  def handle_info({:file_event, watcher, {path, _events}}, %{watcher: watcher} = state)
      when is_binary(path) do
    if relevant_path?(path, state.config) do
      {:noreply, schedule_debounce(state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:file_event, watcher, :stop}, %{watcher: watcher} = state) do
    stop_for_watcher(:unexpected_stop, state)
  end

  def handle_info({:debounced_reconcile, token}, %{debounce_timer: %{token: token}} = state) do
    {:noreply, reconcile_sources(%{state | debounce_timer: nil})}
  end

  def handle_info({:debounced_reconcile, _stale_token}, state), do: {:noreply, state}

  def handle_info({:periodic_reconcile, token}, %{periodic_timer: %{token: token}} = state) do
    state = %{state | periodic_timer: nil}
    {:noreply, state |> reconcile_sources() |> schedule_periodic()}
  end

  def handle_info({:periodic_reconcile, _stale_token}, state), do: {:noreply, state}

  def handle_info({:EXIT, watcher, reason}, %{watcher: watcher} = state) do
    stop_for_watcher(bounded_exit_reason(reason), state)
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    cancel_timer(state.debounce_timer, state.cancel_timer)
    cancel_timer(state.periodic_timer, state.cancel_timer)
    :ok
  end

  defp validate_options(options) do
    validators = [
      {:config, &match?(%Configuration{}, &1)},
      {:notify, &is_pid/1},
      {:file_system, &valid_file_system?/1},
      {:file_system_options, &Keyword.keyword?/1},
      {:scheduler, &is_function(&1, 3)},
      {:cancel_timer, &is_function(&1, 1)},
      {:now, &is_function(&1, 0)}
    ]

    defaults = %{
      file_system: FileSystem,
      file_system_options: [],
      scheduler: &default_schedule/3,
      cancel_timer: &Process.cancel_timer/1,
      now: &DateTime.utc_now/0
    }

    Enum.reduce_while(validators, :ok, fn {key, validator}, :ok ->
      case Keyword.fetch(options, key) do
        {:ok, value} ->
          if validator.(value), do: {:cont, :ok}, else: {:halt, {:error, {:invalid_option, key}}}

        :error ->
          case Map.fetch(defaults, key) do
            {:ok, value} ->
              if validator.(value),
                do: {:cont, :ok},
                else: {:halt, {:error, {:invalid_option, key}}}

            :error ->
              {:halt, {:error, {:invalid_option, key}}}
          end
      end
    end)
  end

  defp valid_file_system?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :start_link, 1) and
      function_exported?(module, :subscribe, 1)
  end

  defp valid_file_system?(_module), do: false

  defp start_watcher(state) do
    directories =
      [state.config.local_proxy_list_path, state.config.local_direct_list_path]
      |> Enum.map(&Path.dirname/1)
      |> Enum.uniq()

    watcher_options = Keyword.put(state.file_system_options, :dirs, directories)

    case state.file_system.start_link(watcher_options) do
      {:ok, watcher} when is_pid(watcher) ->
        case state.file_system.subscribe(watcher) do
          :ok -> {:ok, %{state | watcher: watcher}}
          _invalid -> {:error, :subscribe_failed}
        end

      :ignore ->
        {:error, :start_failed}

      {:error, _reason} ->
        {:error, :start_failed}

      _invalid ->
        {:error, :start_failed}
    end
  rescue
    _error -> {:error, :start_failed}
  catch
    _kind, _reason -> {:error, :start_failed}
  end

  defp reconcile_sources(state) do
    Enum.reduce([:proxy, :direct], state, &reconcile_source/2)
  end

  defp reconcile_source(slot, state) do
    {kind, action, path} = source_spec(slot, state.config)
    previous = Map.fetch!(state.sources, slot)

    case read_source(path, action, kind, state.config.unsupported_rule_sample_limit) do
      {:ok, content, availability} ->
        accept_source(slot, kind, path, content, availability, previous, state)

      {:error, reason} ->
        fail_source(slot, kind, path, reason, previous, state)
    end
  end

  defp read_source(path, action, kind, sample_limit) do
    case File.read(path) do
      {:ok, bytes} ->
        if String.valid?(bytes) do
          content = normalize(bytes)

          if valid_replacement?(content, action, kind, sample_limit),
            do: {:ok, content, :ready},
            else: {:error, :invalid_replacement}
        else
          {:error, :invalid_utf8}
        end

      {:error, :enoent} ->
        {:ok, "", :missing}

      {:error, reason} ->
        {:error, file_failure(reason)}
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

  defp accept_source(slot, kind, path, content, availability, previous, state) do
    observed_at = state.now.()
    hash = sha256(content)

    snapshot = %SourceSnapshot{
      kind: kind,
      content: content,
      content_sha256: hash,
      observed_at: observed_at,
      metadata: %{path: path},
      availability: availability
    }

    cond do
      previous == nil ->
        _ = Telemetry.emit([:local, :source, :change], %{}, %{source: kind})
        send(state.notify, {:proxy_rules_source, kind, snapshot})
        put_source(state, slot, snapshot)

      availability == :missing and previous.availability == :missing ->
        put_source(state, slot, snapshot)

      availability == :missing ->
        fail_source(slot, kind, path, :not_found, previous, state)

      previous.content_sha256 != hash ->
        _ = Telemetry.emit([:local, :source, :change], %{}, %{source: kind})
        send(state.notify, {:proxy_rules_source, kind, snapshot})
        put_source(state, slot, snapshot)

      previous.availability != :ready ->
        metadata = %{path: path, observed_at: observed_at, availability: :ready}
        send(state.notify, {:proxy_rules_source_fresh, kind, metadata})
        put_source(state, slot, snapshot)

      true ->
        put_source(state, slot, snapshot)
    end
  end

  defp fail_source(slot, kind, path, reason, nil, state) do
    observed_at = state.now.()

    snapshot = %SourceSnapshot{
      kind: kind,
      content: "",
      content_sha256: sha256(""),
      observed_at: observed_at,
      metadata: %{path: path},
      availability: :stale
    }

    notify_failure(kind, reason, state)
    put_source(state, slot, snapshot)
  end

  defp fail_source(slot, kind, _path, reason, previous, state) do
    snapshot = %{previous | availability: :stale, observed_at: state.now.()}
    if previous.availability != :stale, do: notify_failure(kind, reason, state)
    put_source(state, slot, snapshot)
  end

  defp notify_failure(kind, reason, state) do
    _ =
      Telemetry.emit([:local, :reconciliation, :failure], %{}, %{
        source: kind,
        failure_category: telemetry_failure(reason)
      })

    send(state.notify, {:proxy_rules_source_status, kind, :stale, reason})
  end

  defp telemetry_failure(:not_found), do: :not_found
  defp telemetry_failure(:permission_denied), do: :permission_denied
  defp telemetry_failure(:invalid_utf8), do: :invalid_utf8
  defp telemetry_failure(_reason), do: :read_failed

  defp stop_for_watcher(reason, state) do
    Enum.each([:local_proxy, :local_direct], fn source ->
      _ =
        Telemetry.emit([:local, :reconciliation, :failure], %{}, %{
          source: source,
          failure_category: :watcher_failed
        })
    end)

    {:stop, {:watcher_failed, reason}, state}
  end

  defp put_source(state, slot, snapshot),
    do: put_in(state, [:sources, slot], snapshot)

  defp source_spec(:proxy, config),
    do: {:local_proxy, :proxy, config.local_proxy_list_path}

  defp source_spec(:direct, config),
    do: {:local_direct, :direct, config.local_direct_list_path}

  defp public_snapshots(%{proxy: proxy, direct: direct}), do: %{proxy: proxy, direct: direct}

  defp relevant_path?(path, config) do
    targets = [config.local_proxy_list_path, config.local_direct_list_path]
    path in targets or path in Enum.map(targets, &Path.dirname/1)
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
  defp file_failure(_reason), do: :read_failed

  defp bounded_exit_reason(reason) when reason in [:normal, :shutdown, :killed], do: reason
  defp bounded_exit_reason(_reason), do: :unexpected_exit

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
end
