defmodule GSMLG.ProxyRules.Transport.HTTPFetch do
  @moduledoc """
  HTTPFetch streaming transport with hard response-body and 64 KiB header limits.

  Header accounting includes each name, value and four delimiter bytes. The
  transport parses response headers before this boundary validates them; rejected
  headers and oversized body chunks are never retained in the returned result.
  """

  @behaviour GSMLG.ProxyRules.Transport

  @allowed_options [:connect_timeout, :receive_timeout, :max_body_size]
  @max_header_bytes 65_536

  @impl true
  def get(url, headers, options) do
    with :ok <- validate_options(options),
         :ok <- validate_url(url),
         :ok <- validate_headers(headers) do
      fetch(url, headers, options)
    end
  end

  @doc false
  @spec header_bytes([{binary(), binary()}]) :: non_neg_integer()
  def header_bytes(headers) do
    Enum.reduce(headers, 0, fn {name, value}, size ->
      size + byte_size(name) + byte_size(value) + 4
    end)
  end

  @doc false
  @spec validate_response_headers([{binary(), binary()}], non_neg_integer()) ::
          :ok | {:error, :headers_too_large}
  def validate_response_headers(headers, retained_size \\ 0)
      when is_list(headers) and is_integer(retained_size) and retained_size >= 0 do
    header_limit_result(header_bytes(headers) + retained_size)
  end

  defp fetch(url, headers, options) do
    timeout = options[:receive_timeout]

    promise =
      HTTP.fetch(url,
        headers: headers,
        http_version: :http1,
        tls_backend: :ssl,
        redirect: :manual,
        decode_body: false,
        stream_response: true,
        timeout: :infinity,
        connect_timeout: Keyword.get(options, :connect_timeout) || timeout,
        read_idle_timeout: timeout,
        response_stream_idle_timeout: timeout
      )

    completion = HTTP.Promise.completion(promise)

    result =
      try do
        case HTTP.Promise.await(promise) do
          %HTTP.Response{} = response -> read_response(response, options)
          {:error, reason} -> {:error, normalize_error(reason)}
        end
      catch
        :exit, {:timeout, _context} -> {:error, :timeout}
        :exit, _reason -> {:error, :transport_error}
      end

    case HTTP.RequestCompletion.abort_and_await(completion, 1_000) do
      :ok -> result
      {:error, _reason} -> {:error, :transport_error}
    end
  end

  defp read_response(response, options) do
    headers = HTTP.Headers.to_list(response.headers)

    with :ok <- validate_response_headers(headers),
         false <- content_length_exceeds?(headers, options[:max_body_size]),
         {:ok, body} <- read_body(response.body, options[:max_body_size]) do
      {:ok, %{status: response.status, headers: headers, body: body}}
    else
      true -> {:error, :body_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp read_body(body, limit) when is_binary(body) do
    if byte_size(body) > limit, do: {:error, :body_too_large}, else: {:ok, body}
  end

  defp read_body(stream, limit) when is_pid(stream) do
    monitor = Process.monitor(stream)

    try do
      send(stream, {:read_chunk, self(), :ack})
      collect_body(stream, monitor, limit, 0, [])
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  defp collect_body(stream, monitor, limit, size, chunks) do
    receive do
      {:stream_chunk, ^stream, chunk, ack_ref} ->
        next_size = size + byte_size(chunk)

        if next_size > limit do
          {:error, :body_too_large}
        else
          send(stream, {:stream_chunk_ack, ack_ref})
          collect_body(stream, monitor, limit, next_size, [chunk | chunks])
        end

      {:stream_trailers, ^stream, _headers} ->
        collect_body(stream, monitor, limit, size, chunks)

      {:stream_end, ^stream} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:stream_error, ^stream, reason} ->
        {:error, normalize_error(reason)}

      {:DOWN, ^monitor, :process, ^stream, _reason} ->
        {:error, :connection_failed}
    end
  end

  defp normalize_error(reason)
       when reason in [:timeout, :request_timeout, :connect_timeout, :read_idle_timeout],
       do: :timeout

  defp normalize_error(reason)
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :closed],
       do: :connection_failed

  defp normalize_error(:headers_too_large), do: :headers_too_large

  defp normalize_error(:invalid_http_response), do: :http_error
  defp normalize_error(_reason), do: :transport_error

  defp valid_connect_timeout?(nil), do: true
  defp valid_connect_timeout?(timeout), do: is_integer(timeout) and timeout > 0

  defp header_limit_result(size) when size <= @max_header_bytes, do: :ok
  defp header_limit_result(_size), do: {:error, :headers_too_large}

  defp content_length_exceeds?(headers, max_body_size) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-length" and
        case Integer.parse(value) do
          {length, ""} -> length > max_body_size
          _other -> false
        end
    end)
  end

  defp validate_options(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @allowed_options)),
         receive_timeout
         when is_integer(receive_timeout) and receive_timeout > 0 and
                receive_timeout <= 4_294_967_295 <-
           Keyword.get(options, :receive_timeout),
         true <- valid_connect_timeout?(Keyword.get(options, :connect_timeout)),
         max_body_size when is_integer(max_body_size) and max_body_size >= 0 <-
           Keyword.get(options, :max_body_size) do
      :ok
    else
      _invalid -> {:error, :invalid_options}
    end
  end

  defp validate_options(_options), do: {:error, :invalid_options}

  defp validate_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{
        scheme: scheme,
        host: host,
        port: port,
        userinfo: nil,
        fragment: nil,
        path: path,
        query: query
      }
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) and port > 0 and port <= 65_535 ->
        if valid_host?(host) and valid_request_target?(path, query),
          do: :ok,
          else: {:error, :invalid_url}

      _uri ->
        {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp validate_url(_url), do: {:error, :invalid_url}

  defp valid_host?(host) do
    String.valid?(host) and
      Enum.all?(:binary.bin_to_list(host), fn byte -> byte > 32 and byte != 127 end)
  end

  defp valid_request_target?(path, query) do
    path = path || "/"
    target = if is_binary(query), do: path <> "?" <> query, else: path

    String.starts_with?(path, "/") and valid_request_target_bytes?(target) and
      valid_percent_encoding?(target)
  end

  defp valid_request_target_bytes?(target) do
    String.valid?(target) and
      Enum.all?(:binary.bin_to_list(target), fn byte -> byte > 32 and byte != 127 end)
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<?%, high, low, rest::binary>>)
       when high in ?0..?9 or high in ?A..?F or high in ?a..?f do
    if low in ?0..?9 or low in ?A..?F or low in ?a..?f,
      do: valid_percent_encoding?(rest),
      else: false
  end

  defp valid_percent_encoding?(<<?%, _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, fn
         {name, value} when is_binary(name) and is_binary(value) ->
           valid_header_name?(name) and valid_header_value?(value)

         _header ->
           false
       end),
       do: :ok,
       else: {:error, :invalid_headers}
  end

  defp validate_headers(_headers), do: {:error, :invalid_headers}

  defp valid_header_name?(name) when byte_size(name) > 0 do
    Enum.all?(:binary.bin_to_list(name), fn byte ->
      byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z or
        byte in ~c"!#$%&'*+-.^_`|~"
    end)
  end

  defp valid_header_name?(_name), do: false

  defp valid_header_value?(value) do
    Enum.all?(:binary.bin_to_list(value), fn byte ->
      byte == 9 or byte in 32..126 or byte >= 128
    end)
  end
end
