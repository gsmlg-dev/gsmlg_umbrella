defmodule GSMLG.CouchDB.Connection do
  @moduledoc """
  HTTP request manager for Apache CouchDB using HTTPFetch.

  This GenServer coordinates concurrent HTTP/1.1 requests to a CouchDB server
  and handles request/response correlation. It provides a clean API for making
  HTTP requests (GET, POST, PUT, DELETE, COPY) with automatic JSON encoding/decoding.

  ## Architecture

  - Single request coordinator per application instance
  - Asynchronous request handling with `GenServer.call/2`
  - Automatic request/response correlation via HTTPFetch
  - Basic authentication on every request
  - JSON response parsing when `Content-Type: application/json`

  ## Configuration

      config :gsmlg_couchdb, GSMLG.CouchDB.Connection,
        scheme: :http,          # or :https
        host: "localhost",
        port: 5984,
        username: "admin",
        password: "password"

  ## Usage

  Most users should use the higher-level `GSMLG.CouchDB.DB` and `GSMLG.CouchDB.Docs`
  modules instead of calling this module directly. However, for custom requests:

      # GET request
      Connection.get("/_all_dbs")
      #=> {:ok, ["_replicator", "_users", "mydb"]}

      # POST request with JSON body
      Connection.post("/mydb", %{type: "user", name: "Alice"})
      #=> {:ok, %{id: "...", ok: true, rev: "1-..."}}

      # PUT request
      Connection.put("/mydb/doc123", %{_rev: "1-...", field: "value"})
      #=> {:ok, %{id: "doc123", ok: true, rev: "2-..."}}

  ## Connection Lifecycle

  Each request owns its HTTPFetch connection and body stream. Transport errors
  are returned to the caller without restarting the coordinator. Shutdown
  cancels pending requests and waits for their network resources to close.

  ## Bang Variants

  All request functions have bang (`!`) variants that raise on error:

      Connection.get!("/_all_dbs")  # Returns data directly or raises
  """
  use GenServer

  defstruct [:conn, :username, :password, :authorization, requests: %{}]

  def start_link(_) do
    # {scheme, host, port}
    conn_conf = Application.get_env(:gsmlg_couchdb, GSMLG.CouchDB.Connection)
    scheme = Keyword.get(conn_conf, :scheme)
    host = Keyword.get(conn_conf, :host)
    port = Keyword.get(conn_conf, :port)
    username = Keyword.get(conn_conf, :username)
    password = Keyword.get(conn_conf, :password)
    GenServer.start_link(__MODULE__, {scheme, host, port, username, password}, name: __MODULE__)
  end

  def get_state() do
    GenServer.call(__MODULE__, {:get_state})
  end

  def request(method, path) do
    GenServer.call(__MODULE__, {:request, method, path, [], ""})
  end

  def request(method, path, body) when is_map(body) do
    body = Jason.encode!(body)
    GenServer.call(__MODULE__, {:request, method, path, [], body})
  end

  def request(method, path, body) when is_binary(body) do
    GenServer.call(__MODULE__, {:request, method, path, [], body})
  end

  def request(method, path, headers, body) do
    GenServer.call(__MODULE__, {:request, method, path, headers, body})
  end

  def head(path, params \\ nil, headers \\ []) do
    path =
      if is_nil(params) do
        path
      else
        path <> "?" <> URI.encode_query(params)
      end

    case GenServer.call(__MODULE__, {:request, "GET", path, headers, ""}) do
      {:ok, %{status: status, headers: _headers}}
      when status >= 200 and status < 300 ->
        {:ok, status}

      {:ok, %{status: status, headers: _headers}} when status >= 400 ->
        {:ok, status}

      {:error, error} ->
        {:error, error}
    end
  end

  def head!(path, params \\ nil, headers \\ []) do
    {:ok, status} = get(path, params, headers)
    status
  end

  def get(path, params \\ nil, headers \\ []) do
    path =
      if is_nil(params) do
        path
      else
        path <> "?" <> URI.encode_query(params)
      end

    case GenServer.call(__MODULE__, {:request, "GET", path, headers, ""}) do
      {:ok, %{data: data, status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        data = parse_response_data(headers, data)
        {:ok, data}

      {:ok, %{data: data, status: status, headers: headers}} when status >= 400 ->
        data = parse_response_data(headers, data)
        {:error, data}

      {:error, error} ->
        {:error, error}
    end
  end

  def get!(path, params \\ nil, headers \\ []) do
    {:ok, data} = get(path, params, headers)
    data
  end

  def post(path, data \\ %{}, headers \\ [{"Content-Type", "application/json"}]) do
    data = Jason.encode!(data)

    case GenServer.call(
           __MODULE__,
           {:request, "POST", path, headers, data}
         ) do
      {:ok, %{data: data, status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        data = parse_response_data(headers, data)
        {:ok, data}

      {:ok, %{data: data, status: status, headers: headers}} when status >= 400 ->
        data = parse_response_data(headers, data)
        {:error, data}

      {:error, error} ->
        {:error, error}
    end
  end

  def post!(path, data \\ %{}, headers \\ [{"Content-Type", "application/json"}]) do
    {:ok, data} = post(path, data, headers)
    data
  end

  def put(path, data \\ %{}, headers \\ [{"Content-Type", "application/json"}]) do
    data = Jason.encode!(data)

    case GenServer.call(
           __MODULE__,
           {:request, "PUT", path, headers, data}
         ) do
      {:ok, %{data: data, status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        data = parse_response_data(headers, data)
        {:ok, data}

      {:ok, %{data: data, status: status, headers: headers}} when status >= 400 ->
        data = parse_response_data(headers, data)
        {:error, data}

      {:error, error} ->
        {:error, error}
    end
  end

  def put!(path, data \\ %{}, headers \\ [{"Content-Type", "application/json"}]) do
    {:ok, data} = put(path, data, headers)
    data
  end

  def delete(path, params \\ nil, headers \\ []) do
    path =
      if is_nil(params) do
        path
      else
        path <> "?" <> URI.encode_query(params)
      end

    case GenServer.call(__MODULE__, {:request, "DELETE", path, headers, ""}) do
      {:ok, %{data: data, status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        data = parse_response_data(headers, data)
        {:ok, data}

      {:ok, %{data: data, status: status, headers: headers}} when status >= 400 ->
        data = parse_response_data(headers, data)
        {:error, data}

      {:error, error} ->
        {:error, error}
    end
  end

  def delete!(path, params \\ nil, headers \\ []) do
    {:ok, data} = delete(path, params, headers)
    data
  end

  def copy(path, params \\ nil, headers \\ []) do
    path =
      if is_nil(params) do
        path
      else
        path <> "?" <> URI.encode_query(params)
      end

    case GenServer.call(__MODULE__, {:request, "COPY", path, headers, ""}) do
      {:ok, %{data: data, status: status, headers: headers}}
      when status >= 200 and status < 300 ->
        data = parse_response_data(headers, data)
        {:ok, data}

      {:ok, %{data: data, status: status, headers: headers}} when status >= 400 ->
        data = parse_response_data(headers, data)
        {:error, data}

      {:error, error} ->
        {:error, error}
    end
  end

  def copy!(path, params \\ nil, headers \\ []) do
    {:ok, data} = copy(path, params, headers)
    data
  end

  ## Callbacks

  @impl true
  def init({scheme, host, port, username, password}) do
    Process.flag(:trap_exit, true)

    {:ok,
     %__MODULE__{
       conn: %URI{scheme: to_string(scheme), host: host, port: port},
       username: username,
       password: password,
       authorization: "Basic " <> Base.encode64("#{username}:#{password}")
     }}
  end

  @impl true
  def handle_call({:request, method, path, headers, body}, from, state) do
    uri = URI.parse(path)
    url = %{state.conn | path: uri.path, query: uri.query}

    promise =
      HTTP.fetch(url,
        method: method,
        request_mode: :proxy,
        headers: headers ++ [{"Authorization", state.authorization}],
        body: body,
        http_version: :http1,
        tls_backend: :ssl,
        redirect: :manual,
        decode_body: false,
        stream_response: true
      )

    request = %{from: from, completion: HTTP.Promise.completion(promise)}
    {:noreply, put_in(state.requests[promise.task.ref], request)}
  end

  def handle_call({:get_state}, _from, state) do
    {:reply, %__MODULE__{conn: state.conn, requests: state.requests}, state}
  end

  @impl true
  def handle_info({ref, %HTTP.Response{} = response}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {request, requests} = Map.pop(state.requests, ref)
    state = %{state | requests: requests}

    headers =
      Enum.map(HTTP.Headers.to_list(response.headers), fn {name, value} ->
        {String.downcase(name), value}
      end)

    result = %{status: response.status, headers: headers, data: ""}

    if is_pid(response.body) do
      stream = response.body
      monitor = Process.monitor(stream)
      send(stream, {:read_chunk, self(), :ack})
      request = Map.merge(request, %{response: result, chunks: [], monitor: monitor})
      {:noreply, put_in(state.requests[stream], request)}
    else
      finish_request(request, {:ok, %{result | data: response.body}})
      {:noreply, state}
    end
  end

  def handle_info({ref, {:error, reason}}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    {request, requests} = Map.pop(state.requests, ref)
    finish_request(request, {:error, reason})
    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:stream_chunk, stream, chunk, ack_ref}, state) do
    state = update_in(state.requests[stream].chunks, &[chunk | &1])
    send(stream, {:stream_chunk_ack, ack_ref})
    {:noreply, state}
  end

  def handle_info({:stream_end, stream}, state) do
    {request, requests} = Map.pop(state.requests, stream)
    Process.demonitor(request.monitor, [:flush])
    data = request.chunks |> Enum.reverse() |> IO.iodata_to_binary()
    finish_request(request, {:ok, %{request.response | data: data}})
    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:stream_error, stream, reason}, state) do
    {request, requests} = Map.pop(state.requests, stream)
    Process.demonitor(request.monitor, [:flush])
    finish_request(request, {:error, reason})
    {:noreply, %{state | requests: requests}}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    key = if Map.has_key?(state.requests, ref), do: ref, else: pid

    case Map.pop(state.requests, key) do
      {nil, _requests} ->
        {:noreply, state}

      {request, requests} ->
        finish_request(request, {:error, reason})
        {:noreply, %{state | requests: requests}}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.requests, fn {_key, request} ->
      finish_request(request, {:error, :closed})
    end)
  end

  defp finish_request(request, result) do
    case HTTP.RequestCompletion.abort_and_await(request.completion, 1_000) do
      :ok -> GenServer.reply(request.from, result)
      {:error, _reason} -> GenServer.reply(request.from, {:error, :transport_error})
    end
  end

  # parse data if response is json
  defp parse_response_data(headers, data) do
    case Enum.find(headers, &(elem(&1, 0) == "content-type")) do
      {"content-type", "application/json"} -> Jason.decode!(data, keys: :atoms)
      _ -> data
    end
  end
end
