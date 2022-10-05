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

  def request(method, path, headers, body) do
    GenServer.call(__MODULE__, {:request, method, path, headers, body})
  end

  def request(method, path, body) when is_binary(body) do
    GenServer.call(__MODULE__, {:request, method, path, [], body})
  end

  def request(method, path, body) when is_map(body) do
    body = Jason.encode!(body)
    GenServer.call(__MODULE__, {:request, method, path, [], body})
  end

  def request(method, path) do
    GenServer.call(__MODULE__, {:request, method, path, [], ""})
  end

  def get(path, params) do
    path = path <> "?" <> URI.encode_query(params)
    GenServer.call(__MODULE__, {:request, "GET", path, [], ""})
  end

  def get(path) do
    GenServer.call(__MODULE__, {:request, "GET", path, [], ""})
  end

  def post(path, data \\ "{}") do
    data = Jason.encode!(data)
    GenServer.call(__MODULE__, {:request, "POST", path, [], data})
  end

  def put(path, data \\ "{}") do
    data = Jason.encode!(data)
    GenServer.call(__MODULE__, {:request, "PUT", path, [], data})
  end

  def delete(path, params) do
    path = path <> "?" <> URI.encode_query(params)
    GenServer.call(__MODULE__, {:request, "DELETE", path, [], ""})
  end

  def delete(path) do
    GenServer.call(__MODULE__, {:request, "DELETE", path, [], ""})
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
    update_in(state.requests[request_ref].response[:data], fn data ->
      case Jason.decode((data || "") <> new_data, keys: :atoms) do
        {:ok, data} -> data
        {:error, _} -> (data || "") <> new_data
      end
    end)
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
end
