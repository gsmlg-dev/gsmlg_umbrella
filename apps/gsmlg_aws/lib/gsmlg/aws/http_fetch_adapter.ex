defmodule GSMLG.AWS.HTTPFetchAdapter do
  @moduledoc """
  Tesla adapter backed by http_fetch, with optional bounded response bodies.

  `:max_body_bytes` rejects oversized Content-Length headers and streamed chunks.
  Redirects are returned to the caller; Tesla middleware owns redirect policy.
  """

  @behaviour Tesla.Adapter

  @impl true
  def call(%Tesla.Env{} = env, options) do
    options = Tesla.Adapter.opts([receive_timeout: 15_000, connect_timeout: 5_000], env, options)
    timeout = options[:receive_timeout]

    promise =
      HTTP.fetch(Tesla.build_url(env),
        method: env.method,
        request_mode: :proxy,
        headers: env.headers,
        body: IO.iodata_to_binary(env.body || ""),
        http_version: :http1,
        tls_backend: :ssl,
        http1_reuse: true,
        redirect: :manual,
        telemetry: false,
        decode_body: false,
        stream_response: true,
        connect_timeout: options[:connect_timeout],
        timeout: Keyword.get(options, :request_timeout, :infinity),
        read_idle_timeout: timeout,
        response_stream_idle_timeout: timeout
      )

    completion = HTTP.Promise.completion(promise)

    try do
      result =
        case HTTP.Promise.await(promise) do
          %HTTP.Response{} = response -> read_response(env, response, options)
          {:error, reason} -> {:error, normalize_error(reason)}
        end

      case result do
        {:ok, _response} -> HTTP.RequestCompletion.await(completion, 1_000)
        {:error, _reason} -> HTTP.RequestCompletion.abort_and_await(completion, 1_000)
      end

      result
    catch
      kind, reason ->
        HTTP.RequestCompletion.abort_and_await(completion, 1_000)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp read_response(env, response, options) do
    headers =
      Enum.map(HTTP.Headers.to_list(response.headers), fn {key, value} ->
        {String.downcase(key), value}
      end)

    limit = Keyword.get(options, :max_body_bytes, :infinity)

    with false <- content_length_exceeds?(headers, limit),
         {:ok, body} <- read_body(response.body, limit, options[:receive_timeout]) do
      {:ok, %{env | status: response.status, headers: headers, body: body}}
    else
      true -> {:error, :response_limit}
      {:error, _reason} = error -> error
    end
  end

  defp read_body(stream, limit, timeout) when is_pid(stream) do
    monitor = Process.monitor(stream)

    try do
      send(stream, {:read_chunk, self(), :ack})
      collect_body(stream, monitor, limit, timeout, 0, [])
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp read_body(body, limit, _timeout) do
    body = body || ""
    if exceeds?(byte_size(body), limit), do: {:error, :response_limit}, else: {:ok, body}
  end

  defp collect_body(stream, monitor, limit, timeout, size, chunks) do
    receive do
      {:stream_chunk, ^stream, chunk, ack_ref} ->
        next_size = size + byte_size(chunk)

        if exceeds?(next_size, limit) do
          {:error, :response_limit}
        else
          send(stream, {:stream_chunk_ack, ack_ref})
          collect_body(stream, monitor, limit, timeout, next_size, [chunk | chunks])
        end

      {:stream_trailers, ^stream, _headers} ->
        collect_body(stream, monitor, limit, timeout, size, chunks)

      {:stream_end, ^stream} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:stream_error, ^stream, reason} ->
        {:error, normalize_error(reason)}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, :closed}
    after
      timeout -> {:error, :timeout}
    end
  end

  defp content_length_exceeds?(headers, limit) do
    Enum.any?(headers, fn
      {"content-length", value} ->
        case Integer.parse(value) do
          {length, ""} -> exceeds?(length, limit)
          _invalid -> false
        end

      _header ->
        false
    end)
  end

  defp exceeds?(_size, :infinity), do: false
  defp exceeds?(size, limit), do: size > limit

  defp normalize_error(reason)
       when reason in [:timeout, :request_timeout, :read_idle_timeout, :connect_timeout],
       do: :timeout

  defp normalize_error(reason), do: reason
end
