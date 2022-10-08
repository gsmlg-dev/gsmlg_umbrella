defmodule GSMLG_CouchDB.Connection do
  @moduledoc """
  Documentation for `GSMLG_CouchDB.Connection`.
  """
  use GenServer

  require Logger

  defstruct [:conn, :username, :password, :authorization, requests: %{}]

  def start_link(_) do
    # {scheme, host, port}
    conn_conf = Application.get_env(:gsmlg_couchdb, GSMLG_CouchDB.Connection)
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

  def post!(path, data \\ %{}, headers \\ []) do
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

  def put!(path, data \\ %{}, headers \\ []) do
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
    case Mint.HTTP.connect(scheme, host, port) do
      {:ok, conn} ->
        state = %__MODULE__{
          conn: conn,
          username: username,
          password: password,
          authorization: "Basic " <> Base.encode64("#{username}:#{password}")
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, path, headers, body}, from, state) do
    headers = headers ++ [{"Authorization", state.authorization}]
    # In both the successful case and the error case, we make sure to update the connection
    # struct in the state since the connection is an immutable data structure.
    case Mint.HTTP.request(state.conn, method, path, headers, body) do
      {:ok, conn, request_ref} ->
        state = put_in(state.conn, conn)
        # We store the caller this request belongs to and an empty map as the response.
        # The map will be filled with status code, headers, and so on.
        state = put_in(state.requests[request_ref], %{from: from, response: %{}})
        {:noreply, state}

      {:error, conn, reason} ->
        state = put_in(state.conn, conn)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_state}, _from, state) do
    rs = %__MODULE__{
      conn: state.conn,
      requests: state.requests
    }

    {:reply, rs, state}
  end

  @impl true
  def handle_info(message, state) do
    # We should handle the error case here as well, but we're omitting it for brevity.
    case Mint.HTTP.stream(state.conn, message) do
      :unknown ->
        _ = Logger.error(fn -> "Received unknown message: " <> inspect(message) end)
        {:noreply, state}

      {:ok, conn, responses} ->
        state = put_in(state.conn, conn)
        state = Enum.reduce(responses, state, &process_response/2)
        {:noreply, state}
    end
  end

  defp process_response({:status, request_ref, status}, state) do
    put_in(state.requests[request_ref].response[:status], status)
  end

  defp process_response({:headers, request_ref, headers}, state) do
    put_in(state.requests[request_ref].response[:headers], headers)
  end

  defp process_response({:data, request_ref, new_data}, state) do
    update_in(state.requests[request_ref].response[:data], fn data -> (data || "") <> new_data end)
  end

  # When the request is done, we use GenServer.reply/2 to reply to the caller that was
  # blocked waiting on this request.
  defp process_response({:done, request_ref}, state) do
    {%{response: response, from: from}, state} = pop_in(state.requests[request_ref])
    GenServer.reply(from, {:ok, response})
    state
  end

  # A request can also error, but we're not handling the erroneous responses for
  # brevity.

  # parse data if response is json
  defp parse_response_data(headers, data) do
    case Enum.find(headers, &(elem(&1, 0) == "content-type")) do
      {"content-type", "application/json"} -> Jason.decode!(data, keys: :atoms)
      _ -> data
    end
  end
end
