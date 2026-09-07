defmodule GSMLG.BrowserAgent.CDP.Client do
  @moduledoc """
  Supervised, bounded owner of one local CDP WebSocket connection.

  Request-stage Fetch interception authorizes URLs before Chromium dispatches them. The
  `Network.responseReceived` peer-address check can only detect and terminate a private-address
  connection after it was made; it does not pin Chromium's DNS result. A production deployment
  therefore still requires a browser-container egress ACL or policy-enforcing pinned proxy to
  prevent DNS rebinding at the socket boundary.
  """

  use GenServer

  alias GSMLG.BrowserAgent.OriginPolicy
  alias GSMLG.BrowserAgent.CDP.Transport.HTTPWebSocket

  @methods [
    "Accessibility.enable",
    "Accessibility.getFullAXTree",
    "Browser.cancelDownload",
    "Browser.setDownloadBehavior",
    "Fetch.continueRequest",
    "Fetch.enable",
    "Fetch.failRequest",
    "DOM.describeNode",
    "DOM.enable",
    "DOM.focus",
    "DOM.getBoxModel",
    "DOM.getDocument",
    "DOM.querySelector",
    "Input.dispatchKeyEvent",
    "Input.dispatchMouseEvent",
    "Input.dispatchMouseWheelEvent",
    "Input.insertText",
    "Network.enable",
    "Page.captureScreenshot",
    "Page.enable",
    "Page.getNavigationHistory",
    "Page.navigate"
  ]

  @document_events [
    "Accessibility.loadComplete",
    "Accessibility.nodesUpdated",
    "DOM.attributeModified",
    "DOM.attributeRemoved",
    "DOM.characterDataModified",
    "DOM.childNodeCountUpdated",
    "DOM.childNodeInserted",
    "DOM.childNodeRemoved",
    "DOM.documentUpdated",
    "DOM.inlineStyleInvalidated",
    "DOM.scrollableFlagUpdated",
    "Page.documentOpened",
    "Page.frameNavigated",
    "Page.frameStartedLoading",
    "Page.navigatedWithinDocument"
  ]

  @type result :: {:ok, map()} | {:error, atom() | {:cdp_error, integer()}}

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.get(opts, :id, make_ref())},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @spec allowed_methods() :: [String.t()]
  def allowed_methods, do: @methods

  @spec await_ready(GenServer.server(), pos_integer()) :: :ok | {:error, atom()}
  def await_ready(client, timeout \\ 5_000)
      when is_integer(timeout) and timeout > 0 and timeout <= 120_000 do
    GenServer.call(client, {:await_ready, timeout}, timeout + 1_000)
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  @spec document_epoch(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, atom()}
  def document_epoch(client) do
    GenServer.call(client, :document_epoch)
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  def enable(client, timeout \\ 5_000) do
    with {:ok, _} <- command(client, "Network.enable", %{}, timeout),
         {:ok, _} <-
           command(
             client,
             "Fetch.enable",
             %{
               "patterns" => [
                 %{
                   "urlPattern" => "*",
                   "requestStage" => "Request"
                 }
               ]
             },
             timeout
           ),
         {:ok, _} <- command(client, "Page.enable", %{}, timeout),
         {:ok, _} <- command(client, "DOM.enable", %{}, timeout),
         {:ok, _} <- command(client, "Accessibility.enable", %{}, timeout) do
      :ok
    end
  end

  def navigate(client, url, timeout),
    do: command(client, "Page.navigate", %{"url" => url}, timeout)

  def navigation_history(client, timeout),
    do: command(client, "Page.getNavigationHistory", %{}, timeout)

  def accessibility_tree(client, timeout),
    do: command(client, "Accessibility.getFullAXTree", %{}, timeout)

  def document(client, timeout), do: command(client, "DOM.getDocument", %{"depth" => 0}, timeout)

  def query_selector(client, node_id, selector, timeout),
    do:
      command(
        client,
        "DOM.querySelector",
        %{"nodeId" => node_id, "selector" => selector},
        timeout
      )

  def describe_node(client, node_id, timeout),
    do: command(client, "DOM.describeNode", %{"nodeId" => node_id}, timeout)

  def describe_backend_node(client, backend_node_id, timeout),
    do:
      command(
        client,
        "DOM.describeNode",
        %{"backendNodeId" => backend_node_id, "depth" => 0, "pierce" => false},
        timeout
      )

  def focus(client, backend_node_id, timeout),
    do: command(client, "DOM.focus", %{"backendNodeId" => backend_node_id}, timeout)

  def box_model(client, backend_node_id, timeout),
    do: command(client, "DOM.getBoxModel", %{"backendNodeId" => backend_node_id}, timeout)

  def mouse_event(client, type, x, y, timeout) when type in ["mousePressed", "mouseReleased"] do
    params = %{
      "type" => type,
      "x" => x,
      "y" => y,
      "button" => "left",
      "clickCount" => 1
    }

    command(client, "Input.dispatchMouseEvent", params, timeout)
  end

  def insert_text(client, text, timeout),
    do: command(client, "Input.insertText", %{"text" => text}, timeout)

  def key_event(client, type, key, modifiers, timeout)
      when type in ["keyDown", "keyUp", "rawKeyDown"] do
    command(
      client,
      "Input.dispatchKeyEvent",
      %{"type" => type, "key" => key, "modifiers" => modifiers},
      timeout
    )
  end

  def scroll(client, delta_x, delta_y, timeout) do
    command(
      client,
      "Input.dispatchMouseWheelEvent",
      %{"x" => 0, "y" => 0, "deltaX" => delta_x, "deltaY" => delta_y},
      timeout
    )
  end

  def screenshot(client, timeout) do
    command(
      client,
      "Page.captureScreenshot",
      %{"format" => "png", "fromSurface" => true},
      timeout
    )
  end

  def prepare_download(client, timeout) do
    with {:ok, token, directory} <- GenServer.call(client, :reserve_download),
         {:ok, _result} <-
           command(
             client,
             "Browser.setDownloadBehavior",
             %{
               "behavior" => "allowAndName",
               "downloadPath" => directory,
               "eventsEnabled" => true
             },
             timeout
           ) do
      {:ok, token}
    else
      {:error, _reason} = error ->
        _ = abandon_reserved_download(client)
        if ambiguous_download_policy_error?(error), do: invalidate(client)
        error
    end
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  def await_download(client, token, timeout) do
    GenServer.call(client, {:await_download, token, timeout}, timeout + 1_000)
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  def finish_download(client, token, timeout) do
    result =
      command(
        client,
        "Browser.setDownloadBehavior",
        %{"behavior" => "deny", "eventsEnabled" => false},
        timeout
      )

    cleanup = finalize_reserved_download(client, token)

    if match?({:error, _reason}, result), do: invalidate(client)

    case {result, cleanup} do
      {{:ok, _result}, :ok} -> :ok
      {{:error, _reason} = error, _cleanup} -> error
      {_result, {:error, _reason} = error} -> error
    end
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, HTTPWebSocket)
    max_message_bytes = Keyword.get(opts, :max_message_bytes, 1_048_576)

    transport_opts =
      opts
      |> Keyword.get(:transport_opts, [])
      |> Keyword.put(:max_message_bytes, max_message_bytes)

    case transport.connect(
           Keyword.fetch!(opts, :url),
           Keyword.get(opts, :headers, []),
           self(),
           transport_opts
         ) do
      {:ok, socket} ->
        {:ok,
         %{
           transport: transport,
           socket: socket,
           connected?: false,
           owner_monitor: monitor_owner(Keyword.get(opts, :owner)),
           document_epoch: 0,
           origin_policy: Keyword.get(opts, :origin_policy),
           resolver: Keyword.get(opts, :resolver),
           policy_timeout_ms: policy_timeout(Keyword.get(opts, :policy_timeout_ms, 1_000)),
           authorized_network_ids: MapSet.new(),
           max_authorized_network_ids:
             network_id_limit(Keyword.get(opts, :max_authorized_network_ids, 1_024)),
           download_dir: Keyword.get(opts, :download_dir),
           max_download_bytes: Keyword.get(opts, :max_download_bytes, 10_485_760),
           active_download: nil,
           ready_waiters: %{},
           pending: %{},
           next_id: 1,
           max_pending: Keyword.get(opts, :max_pending, 64),
           max_message_bytes: max_message_bytes
         }}

      {:error, reason} ->
        {:stop, {:cdp_connect_failed, sanitize_reason(reason)}}
    end
  end

  @impl true
  def handle_call(
        :reserve_download,
        _from,
        %{download_dir: directory, active_download: nil} = state
      )
      when is_binary(directory) do
    case prepare_download_directory(directory) do
      :ok ->
        token = make_ref()

        download = %{
          token: token,
          guid: nil,
          source_url: nil,
          suggested_filename: nil,
          waiter: nil,
          timer: nil,
          result: nil
        }

        {:reply, {:ok, token, directory}, %{state | active_download: download}}

      {:error, _reason} ->
        {:reply, {:error, :download_unavailable}, state}
    end
  end

  def handle_call(:reserve_download, _from, state),
    do: {:reply, {:error, :download_unavailable}, state}

  def handle_call({:await_download, token, timeout}, from, state) do
    case state.active_download do
      %{token: ^token, result: nil, waiter: nil} = download ->
        timer = Process.send_after(self(), {:download_timeout, token}, timeout)
        download = %{download | waiter: from, timer: timer}
        {:noreply, %{state | active_download: download}}

      %{token: ^token, result: result} when not is_nil(result) ->
        {:reply, result, state}

      _missing_or_changed ->
        {:reply, {:error, :download_unavailable}, state}
    end
  end

  def handle_call(:abandon_download, _from, state) do
    state = abandon_download(state)
    {:reply, :ok, state}
  end

  def handle_call({:finalize_download, token}, _from, state) do
    case state.active_download do
      %{token: ^token, guid: guid} when is_binary(guid) ->
        result = cleanup_owned_download(state.download_dir, guid)
        {:reply, result, %{state | active_download: nil}}

      _missing_or_changed ->
        {:reply, {:error, :download_unavailable}, state}
    end
  end

  def handle_call(:document_epoch, _from, state),
    do: {:reply, {:ok, state.document_epoch}, state}

  def handle_call({:await_ready, _timeout}, _from, %{connected?: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:await_ready, timeout}, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:ready_timeout, token}, timeout)
    {:noreply, put_in(state.ready_waiters[token], {from, timer})}
  end

  def handle_call({:command, _method, _params, _timeout}, _from, %{connected?: false} = state) do
    {:reply, {:error, :cdp_disconnected}, state}
  end

  def handle_call({:command, _method, _params, _timeout}, _from, state)
      when map_size(state.pending) >= state.max_pending do
    {:reply, {:error, :cdp_pending_limit}, state}
  end

  def handle_call({:command, method, params, timeout}, from, state)
      when method in @methods and is_map(params) do
    id = state.next_id
    payload = JSON.encode!(%{"id" => id, "method" => method, "params" => params})

    case state.transport.send(state.socket, payload) do
      :ok ->
        timer = Process.send_after(self(), {:command_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer})
        {:noreply, %{state | pending: pending, next_id: id + 1}}

      {:error, _reason} ->
        {:reply, {:error, :cdp_disconnected}, disconnect(state)}
    end
  end

  @impl true
  def handle_info({:cdp_transport, socket, :open}, %{socket: socket} = state),
    do: {:noreply, connect(state)}

  def handle_info({:cdp_transport, socket, {:text, payload}}, %{socket: socket} = state),
    do: handle_payload(payload, state)

  def handle_info({:cdp_transport, socket, {:close, _code}}, %{socket: socket} = state),
    do: {:noreply, disconnect(state)}

  def handle_info({:cdp_transport, socket, {:error, _reason}}, %{socket: socket} = state),
    do: {:noreply, disconnect(state)}

  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :cdp_timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({:ready_timeout, token}, state) do
    case Map.pop(state.ready_waiters, token) do
      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :cdp_timeout})
        {:noreply, %{state | ready_waiters: waiters}}

      {nil, _waiters} ->
        {:noreply, state}
    end
  end

  def handle_info({:download_timeout, token}, state) do
    case state.active_download do
      %{token: ^token, guid: guid, result: nil} ->
        {:noreply, abort_download(state, guid, {:error, :cdp_timeout})}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info(:invalidate_after_download_abort, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_monitor: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    _ = cleanup_download_files(state.download_dir)
    _ = state.transport.close(state.socket)
    :ok
  end

  defp command(client, method, params, timeout)
       when is_integer(timeout) and timeout > 0 and timeout <= 120_000 do
    GenServer.call(client, {:command, method, params, timeout}, timeout + 1_000)
  catch
    :exit, _reason -> {:error, :cdp_disconnected}
  end

  defp handle_payload(payload, state)
       when is_binary(payload) and byte_size(payload) <= state.max_message_bytes do
    case JSON.decode(payload) do
      {:ok, %{"id" => id, "result" => result}} when is_integer(id) and is_map(result) ->
        reply_pending(state, id, {:ok, result})

      {:ok, %{"id" => id, "error" => %{"code" => code}}}
      when is_integer(id) and is_integer(code) ->
        reply_pending(state, id, {:error, {:cdp_error, code}})

      {:ok,
       %{
         "method" => "Fetch.requestPaused",
         "params" => %{"requestId" => request_id, "request" => request} = params
       }}
      when is_binary(request_id) and byte_size(request_id) in 1..256 and is_map(request) ->
        handle_request(state, request_id, params["networkId"], request["url"])

      {:ok,
       %{
         "method" => "Fetch.requestPaused",
         "params" => %{"requestId" => request_id} = params
       }}
      when is_binary(request_id) and byte_size(request_id) in 1..256 ->
        handle_request(state, request_id, params["networkId"], nil)

      {:ok,
       %{
         "method" => "Network.responseReceived",
         "params" => %{
           "requestId" => network_id,
           "response" => response
         }
       }}
      when is_binary(network_id) and is_map(response) ->
        handle_network_response(state, network_id, response)

      {:ok,
       %{
         "method" => "Network.loadingFailed",
         "params" => %{"requestId" => network_id}
       }}
      when is_binary(network_id) ->
        handle_network_failure(state, network_id)

      {:ok, %{"method" => event}}
      when event in ["Fetch.requestPaused", "Network.responseReceived", "Network.loadingFailed"] ->
        {:stop, :normal, policy_violation(state)}

      {:ok,
       %{
         "method" => "Browser.downloadWillBegin",
         "params" => %{
           "guid" => guid,
           "url" => source_url,
           "suggestedFilename" => suggested_filename
         }
       }}
      when is_binary(guid) and byte_size(guid) in 1..256 and is_binary(source_url) and
             byte_size(source_url) in 1..2_048 and is_binary(suggested_filename) and
             byte_size(suggested_filename) in 1..1_024 ->
        {:noreply, begin_download(state, guid, source_url, suggested_filename)}

      {:ok, %{"method" => "Browser.downloadWillBegin"}} ->
        {:noreply, abort_download(state, nil, {:error, :download_failed})}

      {:ok,
       %{
         "method" => "Browser.downloadProgress",
         "params" => %{"guid" => guid, "state" => progress} = params
       }}
      when is_binary(guid) and progress in ["inProgress", "completed", "canceled"] ->
        {:noreply, progress_download(state, guid, progress, params)}

      {:ok, %{"method" => method}} when method in @document_events ->
        {:noreply, %{state | document_epoch: state.document_epoch + 1}}

      {:ok, %{"method" => _event}} ->
        {:noreply, state}

      _invalid ->
        {:noreply, state}
    end
  end

  defp handle_payload(_oversized_or_invalid, state), do: {:noreply, disconnect(state)}

  defp reply_pending(state, id, reply) do
    case Map.pop(state.pending, id) do
      {{from, timer}, pending} ->
        _ = Process.cancel_timer(timer)
        GenServer.reply(from, reply)
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  defp disconnect(state) do
    Enum.each(state.pending, fn {_id, {from, timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :cdp_disconnected})
    end)

    Enum.each(state.ready_waiters, fn {_token, {from, timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :cdp_disconnected})
    end)

    state
    |> complete_download({:error, :cdp_disconnected})
    |> Map.merge(%{connected?: false, pending: %{}, ready_waiters: %{}})
  end

  defp connect(state) do
    Enum.each(state.ready_waiters, fn {_token, {from, timer}} ->
      _ = Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    %{state | connected?: true, ready_waiters: %{}}
  end

  defp sanitize_reason(reason) when is_atom(reason), do: reason
  defp sanitize_reason(_reason), do: :connection_failed

  defp monitor_owner(owner) when is_pid(owner), do: Process.monitor(owner)
  defp monitor_owner(_owner), do: nil

  defp handle_request(state, request_id, network_id, url) do
    allowed? =
      valid_request_id?(request_id) and valid_network_id?(network_id) and
        request_allowed?(state, url) and
        network_capacity_available?(state, network_id)

    {method, params} = request_decision(request_id, allowed?)

    case send_internal_checked(state, method, params) do
      {:ok, state} ->
        state = if allowed?, do: remember_network_id(state, network_id), else: state
        {:noreply, state}

      {:error, state} ->
        {:stop, :normal, disconnect(state)}
    end
  end

  defp handle_network_response(state, network_id, response) do
    url = response["url"]

    allowed_peer? =
      case Map.fetch(response, "remoteIPAddress") do
        {:ok, remote_address} when is_binary(remote_address) ->
          OriginPolicy.global_address?(remote_address)

        :error ->
          response["fromDiskCache"] === true or response["fromServiceWorker"] === true

        {:ok, _invalid} ->
          false
      end

    if valid_network_id?(network_id) and
         MapSet.member?(state.authorized_network_ids, network_id) and
         request_allowed?(state, url) and allowed_peer? do
      {:noreply,
       %{state | authorized_network_ids: MapSet.delete(state.authorized_network_ids, network_id)}}
    else
      {:stop, :normal, policy_violation(state)}
    end
  end

  defp handle_network_failure(state, network_id) do
    if valid_network_id?(network_id) and
         MapSet.member?(state.authorized_network_ids, network_id) do
      {:noreply,
       %{state | authorized_network_ids: MapSet.delete(state.authorized_network_ids, network_id)}}
    else
      {:stop, :normal, policy_violation(state)}
    end
  end

  defp request_decision(request_id, true),
    do: {"Fetch.continueRequest", %{"requestId" => request_id}}

  defp request_decision(request_id, false),
    do:
      {"Fetch.failRequest",
       %{
         "requestId" => request_id,
         "errorReason" => "BlockedByClient"
       }}

  defp request_allowed?(%{origin_policy: %OriginPolicy{} = policy} = state, url) do
    bounded_policy_check(state.policy_timeout_ms, fn ->
      opts = if is_function(state.resolver, 1), do: [resolver: state.resolver], else: []
      match?({:ok, _origin}, OriginPolicy.authorize(policy, url, opts))
    end)
  rescue
    _exception -> false
  catch
    _kind, _reason -> false
  end

  defp request_allowed?(_state, _url), do: false

  defp bounded_policy_check(timeout, fun) do
    caller = self()
    result_ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        result =
          try do
            fun.()
          rescue
            _exception -> false
          catch
            _kind, _reason -> false
          end

        send(caller, {result_ref, result})
      end)

    receive do
      {^result_ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        result == true

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        false
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        false
    end
  end

  defp valid_request_id?(request_id),
    do: String.valid?(request_id) and byte_size(request_id) in 1..256

  defp network_capacity_available?(state, network_id) do
    MapSet.member?(state.authorized_network_ids, network_id) or
      MapSet.size(state.authorized_network_ids) < state.max_authorized_network_ids
  end

  defp remember_network_id(state, network_id) do
    if valid_network_id?(network_id) do
      %{state | authorized_network_ids: MapSet.put(state.authorized_network_ids, network_id)}
    else
      state
    end
  end

  defp valid_network_id?(network_id),
    do: is_binary(network_id) and String.valid?(network_id) and byte_size(network_id) in 1..256

  defp policy_violation(state) do
    state
    |> Map.update!(:document_epoch, &(&1 + 1))
    |> disconnect()
  end

  defp policy_timeout(value) when is_integer(value) and value in 1..5_000, do: value
  defp policy_timeout(_value), do: 1_000

  defp network_id_limit(value) when is_integer(value) and value in 1..4_096, do: value
  defp network_id_limit(_value), do: 1_024

  defp begin_download(%{active_download: %{guid: nil} = download} = state, guid, url, filename) do
    if valid_download_guid?(guid) do
      accept_download(state, download, guid, url, filename)
    else
      abort_download(state, nil, {:error, :download_failed})
    end
  end

  defp begin_download(state, _guid, _url, _filename), do: state

  defp accept_download(state, download, guid, url, filename) do
    download = %{
      download
      | guid: guid,
        source_url: url,
        suggested_filename: filename
    }

    %{state | active_download: download}
  end

  defp valid_download_guid?(guid) do
    byte_size(guid) <= 128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/, guid)
  end

  defp progress_download(%{active_download: %{guid: guid}} = state, guid, "inProgress", params) do
    case progress_size(params) do
      {:ok, size} when size > state.max_download_bytes ->
        abort_download(state, guid, {:error, :artifact_too_large})

      {:ok, _size} ->
        state

      :error ->
        abort_download(state, guid, {:error, :download_failed})
    end
  end

  defp progress_download(%{active_download: %{guid: guid}} = state, guid, "completed", params) do
    result = read_download(state, params)
    complete_download(state, result)
  end

  defp progress_download(%{active_download: %{guid: guid}} = state, guid, "canceled", _params) do
    complete_download(state, {:error, :download_failed})
  end

  defp progress_download(state, _guid, _progress, _params), do: state

  defp progress_size(params) do
    received = Map.get(params, "receivedBytes")
    total = Map.get(params, "totalBytes")

    if is_number(received) and received >= 0 and is_number(total) and total >= 0 do
      {:ok, max(received, total)}
    else
      :error
    end
  end

  defp read_download(state, params) do
    with total when is_number(total) and total >= 0 <- Map.get(params, "totalBytes", 0),
         true <- total <= state.max_download_bytes,
         {:ok, path, size} <-
           single_regular_download(state.download_dir, state.active_download.guid),
         true <- size <= state.max_download_bytes,
         {:ok, content} <- File.read(path),
         true <- byte_size(content) == size do
      download = state.active_download

      {:ok,
       %{
         content: content,
         source_url: download.source_url,
         suggested_filename: download.suggested_filename
       }}
    else
      false ->
        cleanup_download_files(state.download_dir)
        {:error, :artifact_too_large}

      _invalid ->
        cleanup_download_files(state.download_dir)
        {:error, :download_failed}
    end
  end

  defp single_regular_download(directory, guid) do
    with true <- valid_download_guid?(guid),
         {:ok, [^guid]} <- File.ls(directory),
         path = Path.join(directory, guid),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.lstat(path) do
      {:ok, path, size}
    else
      _invalid -> {:error, :download_failed}
    end
  end

  defp complete_download(%{active_download: nil} = state, _result), do: state

  defp complete_download(%{active_download: download} = state, result) do
    unless match?({:ok, _artifact}, result), do: cleanup_download_files(state.download_dir)

    if download.waiter do
      _ = Process.cancel_timer(download.timer)
      GenServer.reply(download.waiter, result)
    end

    %{state | active_download: %{download | result: result, waiter: nil, timer: nil}}
  end

  defp abort_download(%{active_download: nil} = state, _guid, _result), do: state

  defp abort_download(state, guid, result) do
    state =
      if is_binary(guid) and valid_download_guid?(guid) do
        send_internal(state, "Browser.cancelDownload", %{"guid" => guid})
      else
        state
      end

    state =
      state
      |> send_internal("Browser.setDownloadBehavior", %{
        "behavior" => "deny",
        "eventsEnabled" => false
      })
      |> complete_download(result)

    send(self(), :invalidate_after_download_abort)
    state
  end

  defp send_internal(state, method, params) when method in @methods do
    case send_internal_checked(state, method, params) do
      {:ok, state} -> state
      {:error, state} -> state
    end
  end

  defp send_internal_checked(state, method, params) when method in @methods do
    id = state.next_id
    payload = JSON.encode!(%{"id" => id, "method" => method, "params" => params})

    case state.transport.send(state.socket, payload) do
      :ok -> {:ok, %{state | next_id: id + 1}}
      {:error, _reason} -> {:error, %{state | next_id: id + 1}}
    end
  end

  defp abandon_reserved_download(client) do
    GenServer.call(client, :abandon_download)
  catch
    :exit, _reason -> :ok
  end

  defp finalize_reserved_download(client, token) do
    GenServer.call(client, {:finalize_download, token})
  catch
    :exit, _reason -> {:error, :download_unavailable}
  end

  defp ambiguous_download_policy_error?({:error, reason}),
    do: reason in [:cdp_disconnected, :cdp_timeout]

  defp invalidate(client) do
    GenServer.stop(client, :normal)
  catch
    :exit, _reason -> :ok
  end

  defp abandon_download(%{active_download: nil} = state), do: state

  defp abandon_download(state) do
    if state.active_download.waiter do
      _ = Process.cancel_timer(state.active_download.timer)
      GenServer.reply(state.active_download.waiter, {:error, :download_failed})
    end

    _ = cleanup_download_files(state.download_dir)
    %{state | active_download: nil}
  end

  defp cleanup_download_files(directory) when is_binary(directory) do
    case File.ls(directory) do
      {:ok, names} ->
        Enum.each(names, fn name ->
          if Path.basename(name) == name do
            path = Path.join(directory, name)

            case File.lstat(path) do
              {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] -> _ = File.rm(path)
              _other -> :ok
            end
          end
        end)

      _error ->
        :ok
    end

    :ok
  end

  defp cleanup_download_files(_directory), do: :ok

  defp cleanup_owned_download(directory, guid)
       when is_binary(directory) and is_binary(guid) do
    with true <- valid_download_guid?(guid),
         path = Path.join(directory, guid),
         {:ok, %File.Stat{type: type}} when type in [:regular, :symlink] <- File.lstat(path),
         :ok <- File.rm(path) do
      :ok
    else
      {:error, :enoent} -> :ok
      _invalid -> {:error, :download_unavailable}
    end
  end

  defp cleanup_owned_download(_directory, _guid), do: {:error, :download_unavailable}

  defp prepare_download_directory(directory) do
    with :ok <- File.mkdir_p(directory),
         :ok <- cleanup_download_files(directory),
         {:ok, []} <- File.ls(directory) do
      :ok
    else
      _error -> {:error, :download_unavailable}
    end
  end
end
