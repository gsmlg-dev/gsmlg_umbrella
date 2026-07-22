defmodule GSMLG.ProxyRules.Source.Remote do
  @moduledoc """
  Non-blocking, conditional remote source ingestion with durable cache recovery.
  """

  use GenServer

  alias GSMLG.ProxyRules.{Configuration, Persistence, SourceSnapshot, Telemetry}
  alias GSMLG.ProxyRules.Parser.GFWList

  @type failure ::
          :invalid_response
          | :unexpected_status
          | :not_modified_without_cache
          | :invalid_base64
          | :invalid_utf8
          | :body_too_large
          | :persistence_failed
          | :task_crash
          | GSMLG.ProxyRules.Transport.error_reason()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    transport = Keyword.get(options, :transport, GSMLG.ProxyRules.Transport.Finch)

    if valid_transport?(transport) do
      {gen_options, options} = Keyword.split(options, [:name])
      GenServer.start_link(__MODULE__, options, gen_options)
    else
      {:error, {:invalid_option, :transport}}
    end
  end

  @spec refresh(GenServer.server()) :: {:ok, :accepted}
  def refresh(server), do: GenServer.call(server, :refresh)

  @doc false
  @spec retry_delay(pos_integer(), pos_integer(), non_neg_integer(), boolean(), (pos_integer() ->
                                                                                   pos_integer())) ::
          pos_integer()
  def retry_delay(minimum, maximum, attempt, jitter?, random)
      when is_integer(minimum) and minimum > 0 and is_integer(maximum) and maximum >= minimum and
             is_integer(attempt) and attempt >= 0 and is_boolean(jitter?) and
             is_function(random, 1) do
    delay = capped_exponential(minimum, maximum, attempt)

    if jitter? do
      case random.(delay) do
        value when is_integer(value) and value >= 1 and value <= delay -> value
        _invalid -> delay
      end
    else
      delay
    end
  end

  @impl true
  def init(options) do
    config = Keyword.fetch!(options, :config)
    true = match?(%Configuration{}, config)
    transport = Keyword.get(options, :transport, GSMLG.ProxyRules.Transport.Finch)

    if valid_transport?(transport) do
      {:ok, initial_state(options, config, transport), {:continue, :restore}}
    else
      {:stop, {:invalid_option, :transport}}
    end
  end

  defp initial_state(options, config, transport) do
    %{
      config: config,
      transport: transport,
      transport_options: Keyword.get(options, :transport_options, []),
      notify: Keyword.fetch!(options, :notify),
      task_supervisor: Keyword.fetch!(options, :task_supervisor),
      persistence: Keyword.get(options, :persistence, Persistence),
      persistence_options: Keyword.get(options, :persistence_options, []),
      scheduler: Keyword.get(options, :scheduler, &default_schedule/3),
      cancel_timer: Keyword.get(options, :cancel_timer, &Process.cancel_timer/1),
      now: Keyword.get(options, :now, &DateTime.utc_now/0),
      random: Keyword.get(options, :random, &:rand.uniform/1),
      initial_fetch: Keyword.get(options, :initial_fetch, true),
      source: nil,
      active_task: nil,
      timer: nil,
      retry_attempt: 0
    }
  end

  @impl true
  def handle_continue(:restore, state) do
    state = restore_cache(state)
    if state.initial_fetch, do: {:noreply, start_fetch(state)}, else: {:noreply, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = cancel_timer(state)
    state = if state.active_task, do: state, else: start_fetch(state)
    {:reply, {:ok, :accepted}, state}
  end

  @impl true
  def handle_info({:scheduled_refresh, token}, %{timer: %{token: token}} = state) do
    state = %{state | timer: nil}
    {:noreply, if(state.active_task, do: state, else: start_fetch(state))}
  end

  def handle_info({:scheduled_refresh, _stale_token}, state), do: {:noreply, state}

  def handle_info({reference, result}, %{active_task: %{ref: reference}} = state) do
    Process.demonitor(reference, [:flush])
    state = %{state | active_task: nil}
    {:noreply, handle_fetch_result(result, state)}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{active_task: %{ref: reference}} = state
      ) do
    state = %{state | active_task: nil}
    {:noreply, fetch_failed(:task_crash, state, reason)}
  end

  def handle_info({:DOWN, _reference, :process, _pid, _reason}, state), do: {:noreply, state}

  defp restore_cache(state) do
    case state.persistence.read_remote(state.config.state_directory, state.persistence_options) do
      {:ok, %SourceSnapshot{} = snapshot} ->
        send(state.notify, {:proxy_rules_source, :remote, snapshot})
        %{state | source: snapshot}

      {:error, _finite_reason} ->
        state
    end
  rescue
    _error -> state
  catch
    _kind, _reason -> state
  end

  defp start_fetch(state) do
    headers = conditional_headers(state.source)
    options = transport_options(state.config, state.transport_options)
    transport = state.transport
    options = request_options(transport, options)
    url = state.config.source_url
    started = System.monotonic_time()

    _ = Telemetry.emit([:remote, :fetch, :start], %{}, %{source: :gfwlist})

    task =
      Task.Supervisor.async_nolink(state.task_supervisor, fn ->
        {transport.get(url, headers, options), started}
      end)

    %{state | active_task: %{ref: task.ref, pid: task.pid}}
  end

  defp handle_fetch_result({result, started}, state) do
    duration = System.monotonic_time() - started

    case result do
      {:ok, %{status: 200, headers: headers, body: body}}
      when is_list(headers) and is_binary(body) ->
        if valid_headers?(headers) do
          handle_200(body, headers, duration, state)
        else
          fetch_failed(:invalid_response, state)
        end

      {:ok, %{status: 304, headers: headers, body: body}}
      when is_list(headers) and is_binary(body) ->
        if valid_headers?(headers),
          do: handle_304(headers, duration, state),
          else: fetch_failed(:invalid_response, state)

      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and status >= 100 and status <= 599 and is_list(headers) and
             is_binary(body) ->
        _ =
          Telemetry.emit([:remote, :fetch, :stop], %{duration: duration}, %{
            source: :gfwlist,
            status: status
          })

        fetch_failed(:unexpected_status, state)

      {:error, reason} when is_atom(reason) ->
        fetch_failed(reason, state)

      _invalid ->
        fetch_failed(:invalid_response, state)
    end
  end

  defp handle_fetch_result(_invalid, state), do: fetch_failed(:invalid_response, state)

  defp handle_200(body, headers, duration, state) do
    cond do
      byte_size(body) > state.config.remote_max_body_size ->
        fetch_failed(:body_too_large, state)

      true ->
        case GFWList.decode(body) do
          {:ok, content} -> persist_200(body, content, headers, duration, state)
          {:error, reason} -> fetch_failed(reason, state)
        end
    end
  end

  defp persist_200(body, content, headers, duration, state) do
    fetched_at = state.now.()
    hash = sha256(content)

    snapshot = %SourceSnapshot{
      kind: :remote,
      content: content,
      content_sha256: hash,
      observed_at: fetched_at,
      metadata: %{
        source_url: state.config.source_url,
        etag: response_header(headers, "etag"),
        last_modified: response_header(headers, "last-modified"),
        fetched_at: fetched_at
      }
    }

    case persist(state, body, snapshot) do
      :ok ->
        _ =
          Telemetry.emit(
            [:remote, :fetch, :stop],
            %{duration: duration, response_size: byte_size(body)},
            %{source: :gfwlist, status: 200}
          )

        if state.source && state.source.content_sha256 == hash do
          send(state.notify, {:proxy_rules_source_fresh, :remote, snapshot.metadata})
        else
          send(state.notify, {:proxy_rules_source, :remote, snapshot})
        end

        success(%{state | source: snapshot})

      {:error, _reason} ->
        fetch_failed(:persistence_failed, state)
    end
  end

  defp handle_304(_headers, _duration, %{source: nil} = state),
    do: fetch_failed(:not_modified_without_cache, state)

  defp handle_304(headers, duration, state) do
    fetched_at = state.now.()

    metadata = %{
      state.source.metadata
      | etag: response_header(headers, "etag") || state.source.metadata.etag,
        last_modified:
          response_header(headers, "last-modified") || state.source.metadata.last_modified,
        fetched_at: fetched_at
    }

    snapshot = %{state.source | observed_at: fetched_at, metadata: metadata}

    case current_raw_body(state) do
      {:ok, body} -> persist_304(body, snapshot, metadata, duration, state)
      {:error, _reason} -> fetch_failed(:persistence_failed, state)
    end
  end

  defp persist_304(body, snapshot, metadata, duration, state) do
    case persist(state, body, snapshot) do
      :ok ->
        _ =
          Telemetry.emit([:remote, :fetch, :not_modified], %{duration: duration}, %{
            source: :gfwlist,
            status: 304
          })

        send(state.notify, {:proxy_rules_source_fresh, :remote, metadata})
        success(%{state | source: snapshot})

      {:error, _reason} ->
        fetch_failed(:persistence_failed, state)
    end
  end

  defp current_raw_body(state) do
    path = Path.join(state.config.state_directory, "remote.body")
    maximum = state.config.remote_max_body_size

    case :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      {:ok, file} ->
        result =
          case :file.read(file, maximum + 1) do
            {:ok, body} when byte_size(body) <= maximum -> {:ok, body}
            {:ok, _body} -> {:error, :body_too_large}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
          end

        _ = :file.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist(state, body, snapshot) do
    state.persistence.write_remote(
      state.config.state_directory,
      body,
      snapshot,
      state.persistence_options
    )
  rescue
    _error -> {:error, :persistence_failed}
  catch
    _kind, _reason -> {:error, :persistence_failed}
  end

  defp success(state) do
    state
    |> Map.put(:retry_attempt, 0)
    |> schedule(state.config.remote_refresh_interval)
  end

  defp fetch_failed(reason, state, _detail \\ nil) do
    category = telemetry_failure(reason)

    _ =
      Telemetry.emit([:remote, :fetch, :exception], %{}, %{
        source: :gfwlist,
        failure_category: category
      })

    delay =
      retry_delay(
        state.config.retry_min_interval,
        state.config.retry_max_interval,
        state.retry_attempt,
        state.config.retry_jitter,
        state.random
      )

    state
    |> Map.update!(:retry_attempt, &min(&1 + 1, 1_000_000))
    |> schedule(delay)
  end

  defp telemetry_failure(reason)
       when reason in [
              :invalid_base64,
              :invalid_utf8,
              :body_too_large,
              :persistence_failed,
              :task_crash
            ],
       do: reason

  defp telemetry_failure(reason) do
    if GSMLG.ProxyRules.Transport.valid_error_reason?(reason),
      do: reason,
      else: :unexpected_status
  end

  defp schedule(state, delay) do
    state = cancel_timer(state)
    token = make_ref()
    reference = state.scheduler.(self(), {:scheduled_refresh, token}, delay)
    %{state | timer: %{ref: reference, token: token}}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(state) do
    _ = state.cancel_timer.(state.timer.ref)
    %{state | timer: nil}
  end

  defp conditional_headers(nil), do: []

  defp conditional_headers(snapshot) do
    []
    |> maybe_header("if-none-match", snapshot.metadata.etag)
    |> maybe_header("if-modified-since", snapshot.metadata.last_modified)
  end

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: headers ++ [{name, value}]

  defp transport_options(config, extra) do
    Keyword.merge(
      [
        connect_timeout: config.remote_connect_timeout,
        receive_timeout: config.remote_receive_timeout,
        max_body_size: config.remote_max_body_size
      ],
      extra
    )
  end

  # Finch connection establishment is configured on its pool child. The
  # per-request transport boundary retains connect_timeout for injected
  # transports, while the Finch adapter receives only options it can apply.
  defp request_options(GSMLG.ProxyRules.Transport.Finch, options),
    do: Keyword.delete(options, :connect_timeout)

  defp request_options(_transport, options), do: options

  defp valid_headers?(headers) do
    Enum.reduce_while(headers, 0, fn
      {name, value}, size when is_binary(name) and is_binary(value) ->
        new_size = size + byte_size(name) + byte_size(value) + 4

        if String.valid?(name) and String.valid?(value) and byte_size(name) <= 1_024 and
             byte_size(value) <= 8_192 and new_size <= 65_536,
           do: {:cont, new_size},
           else: {:halt, :invalid}

      _header, _size ->
        {:halt, :invalid}
    end) != :invalid
  end

  defp response_header(headers, wanted) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) == wanted, do: value
    end)
  end

  defp capped_exponential(minimum, maximum, attempt) do
    do_capped_exponential(minimum, maximum, attempt)
  end

  defp do_capped_exponential(value, maximum, _attempt) when value >= maximum, do: maximum
  defp do_capped_exponential(value, _maximum, 0), do: value

  defp do_capped_exponential(value, maximum, attempt),
    do: do_capped_exponential(min(value * 2, maximum), maximum, attempt - 1)

  defp default_schedule(server, message, delay), do: Process.send_after(server, message, delay)
  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp valid_transport?(transport) when is_atom(transport) do
    Code.ensure_loaded?(transport) and function_exported?(transport, :get, 3)
  end

  defp valid_transport?(_transport), do: false
end
