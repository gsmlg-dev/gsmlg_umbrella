defmodule GSMLG.BrowserAgent.Backends.CloakBrowser.Transport.HTTPFetch do
  @moduledoc false

  @behaviour GSMLG.BrowserAgent.Backends.CloakBrowser.Transport

  @max_header_bytes 65_536

  @impl true
  def request(method, url, headers, body, options) do
    timeout = Keyword.fetch!(options, :receive_timeout)

    promise =
      HTTP.fetch(url,
        method: method,
        headers: headers,
        body: body,
        redirect: :manual,
        stream_response: true,
        decode_body: false,
        telemetry: false,
        http_version: :http1,
        tls_backend: :ssl,
        connect_timeout: Keyword.fetch!(options, :connect_timeout),
        timeout: timeout,
        read_idle_timeout: timeout,
        response_stream_idle_timeout: timeout,
        response_stream_ack_timeout: timeout
      )

    completion = HTTP.Promise.completion(promise)

    result =
      try do
        case HTTP.Promise.await(promise) do
          %HTTP.Response{} = response ->
            consume_response(response, Keyword.fetch!(options, :max_body_bytes), timeout)

          {:error, reason} ->
            {:error, normalize_error(reason)}
        end
      after
        # Also cancels a response rejected at headers or before its final stream ACK.
        _ = HTTP.RequestCompletion.abort_and_await(completion, timeout)
      end

    result
  rescue
    ArgumentError -> {:error, :connection_failed}
  catch
    :exit, :timeout -> {:error, :timeout}
    :exit, {:timeout, _context} -> {:error, :timeout}
    :exit, _reason -> {:error, :connection_failed}
  end

  @doc false
  def initial_accumulator do
    %{status: nil, body: [], body_size: 0, header_size: 0, error: nil}
  end

  @doc false
  def reduce_response({:status, status}, state, _max_body_bytes) do
    {:cont, %{state | status: status}}
  end

  def reduce_response({:headers, headers}, state, max_body_bytes) do
    header_size =
      Enum.reduce(headers, state.header_size, fn {name, value}, size ->
        size + byte_size(name) + byte_size(value) + 4
      end)

    cond do
      header_size > @max_header_bytes ->
        {:halt, %{state | error: :headers_too_large}}

      content_length_exceeds?(headers, max_body_bytes) ->
        {:halt, %{state | error: :body_too_large}}

      true ->
        {:cont, %{state | header_size: header_size}}
    end
  end

  def reduce_response({:data, chunk}, state, max_body_bytes) do
    new_size = state.body_size + byte_size(chunk)

    if new_size > max_body_bytes do
      {:halt, %{state | error: :body_too_large}}
    else
      {:cont, %{state | body: [chunk | state.body], body_size: new_size}}
    end
  end

  def reduce_response({:trailers, _headers}, state, _max_body_bytes), do: {:cont, state}

  defp consume_response(response, max_body_bytes, timeout) do
    state = %{initial_accumulator() | status: response.status}

    case reduce_response(
           {:headers, HTTP.Headers.to_list(response.headers)},
           state,
           max_body_bytes
         ) do
      {:halt, state} -> {:error, state.error}
      {:cont, state} -> consume_body(response.body, state, max_body_bytes, timeout)
    end
  end

  defp consume_body(stream, state, max_body_bytes, timeout) when is_pid(stream) do
    monitor = Process.monitor(stream)

    try do
      send(stream, {:read_chunk, self(), :ack})
      receive_body(stream, monitor, state, max_body_bytes, timeout)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp consume_body(body, state, max_body_bytes, _timeout) when is_binary(body) do
    case reduce_response({:data, body}, state, max_body_bytes) do
      {:cont, state} -> normalize_result(state)
      {:halt, state} -> {:error, state.error}
    end
  end

  defp receive_body(stream, monitor, state, max_body_bytes, timeout) do
    receive do
      {:stream_chunk, ^stream, chunk, ack_ref} ->
        case reduce_response({:data, chunk}, state, max_body_bytes) do
          {:halt, state} ->
            {:error, state.error}

          {:cont, state} ->
            send(stream, {:stream_chunk_ack, ack_ref})
            receive_body(stream, monitor, state, max_body_bytes, timeout)
        end

      {:stream_trailers, ^stream, _headers} ->
        receive_body(stream, monitor, state, max_body_bytes, timeout)

      {:stream_end, ^stream} ->
        normalize_result(state)

      {:stream_error, ^stream, reason} ->
        {:error, normalize_error(reason)}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, :connection_failed}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp normalize_result(%{status: status, body: chunks}) when is_integer(status),
    do: {:ok, %{status: status, body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}

  defp normalize_error(reason)
       when reason in [:timeout, :request_timeout, :read_idle_timeout, :connect_timeout],
       do: :timeout

  defp normalize_error(:headers_too_large), do: :headers_too_large
  defp normalize_error(_reason), do: :connection_failed

  defp content_length_exceeds?(headers, max_body_bytes) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-length" and
        case Integer.parse(value) do
          {length, ""} -> length > max_body_bytes
          _invalid -> false
        end
    end)
  end
end
