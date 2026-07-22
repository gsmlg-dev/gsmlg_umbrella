defmodule GSMLG.ProxyRules.Transport.Finch do
  @moduledoc """
  Finch-backed streaming HTTP transport with a hard response-body limit.

  Retained response headers are capped at 64 KiB, counting each name, value,
  and four bytes of delimiter overhead. Finch/Mint necessarily parses an
  individual header event before invoking the reducer, but no over-limit event
  is retained in reducer state or returned to callers.
  """

  @behaviour GSMLG.ProxyRules.Transport

  @allowed_options [:finch_name, :receive_timeout, :max_body_size]
  @max_header_bytes 65_536

  @impl true
  def get(url, headers, options) do
    with :ok <- validate_options(options),
         :ok <- validate_url(url),
         :ok <- validate_headers(headers),
         :ok <- validate_finch(options[:finch_name]) do
      request = Finch.build(:get, url, headers)
      stream(request, options)
    end
  end

  defp stream(request, options) do
    initial = %{
      status: nil,
      headers: [],
      header_size: 0,
      body: [],
      body_size: 0,
      error: nil
    }

    result =
      Finch.stream_while(
        request,
        options[:finch_name],
        initial,
        &reduce_response(&1, &2, options[:max_body_size]),
        receive_timeout: options[:receive_timeout]
      )

    normalize_result(result)
  rescue
    error in ArgumentError -> normalize_expected_argument_error(error)
  catch
    :exit, :timeout -> {:error, :timeout}
    :exit, {:timeout, _context} -> {:error, :timeout}
    :exit, :noproc -> {:error, :connection_failed}
    :exit, {:noproc, _context} -> {:error, :connection_failed}
  end

  defp reduce_response({:status, status}, accumulator, _max_body_size) do
    {:cont,
     %{
       accumulator
       | status: status,
         headers: [],
         header_size: 0,
         body: [],
         body_size: 0,
         error: nil
     }}
  end

  defp reduce_response({:headers, headers}, accumulator, max_body_size) do
    header_size = accumulator.header_size + headers_size(headers)

    cond do
      header_size > @max_header_bytes ->
        {:halt, %{accumulator | error: :headers_too_large}}

      final_response?(accumulator.status) and content_length_exceeds?(headers, max_body_size) ->
        {:halt, %{accumulator | error: :body_too_large}}

      true ->
        {:cont,
         %{
           accumulator
           | headers: accumulator.headers ++ headers,
             header_size: header_size
         }}
    end
  end

  defp reduce_response({:trailers, _trailers}, accumulator, _max_body_size),
    do: {:cont, accumulator}

  defp reduce_response({:data, chunk}, accumulator, max_body_size) do
    body_size = accumulator.body_size + byte_size(chunk)

    if body_size > max_body_size do
      {:halt, %{accumulator | error: :body_too_large}}
    else
      {:cont, %{accumulator | body: [chunk | accumulator.body], body_size: body_size}}
    end
  end

  defp normalize_result({:ok, %{error: :body_too_large}}), do: {:error, :body_too_large}
  defp normalize_result({:ok, %{error: :headers_too_large}}), do: {:error, :headers_too_large}

  defp normalize_result({:ok, %{status: status, headers: headers, body: body}})
       when is_integer(status) do
    {:ok,
     %{status: status, headers: headers, body: body |> Enum.reverse() |> IO.iodata_to_binary()}}
  end

  defp normalize_result({:ok, _accumulator}), do: {:error, :http_error}
  defp normalize_result({:error, error, _accumulator}), do: {:error, normalize_error(error)}

  defp normalize_error(%Finch.TransportError{reason: :timeout}), do: :timeout

  defp normalize_error(%Finch.TransportError{reason: reason})
       when reason in [:econnrefused, :nxdomain, :ehostunreach, :enetunreach, :closed],
       do: :connection_failed

  defp normalize_error(%Finch.TransportError{}), do: :transport_error
  defp normalize_error(%Finch.HTTPError{}), do: :http_error

  defp normalize_error(%Finch.Error{reason: reason})
       when reason in [:could_not_connect, :connection_closed, :connection_dead, :disconnected],
       do: :connection_failed

  defp normalize_error(%Finch.Error{reason: :request_timeout}), do: :timeout
  defp normalize_error(%Finch.Error{}), do: :transport_error
  defp normalize_error(_error), do: :transport_error

  defp normalize_expected_argument_error(%ArgumentError{message: "unknown registry:" <> _rest}),
    do: {:error, :connection_failed}

  defp normalize_expected_argument_error(%ArgumentError{message: message} = error) do
    if String.starts_with?(message, "Finch instance ") and
         String.ends_with?(message, " is not running") do
      {:error, :connection_failed}
    else
      raise error
    end
  end

  defp headers_size(headers) do
    Enum.reduce(headers, 0, fn {name, value}, size ->
      size + byte_size(name) + byte_size(value) + 4
    end)
  end

  defp content_length_exceeds?(headers, max_body_size) do
    Enum.any?(headers, fn {name, value} ->
      String.downcase(name) == "content-length" and
        case Integer.parse(value) do
          {length, ""} -> length > max_body_size
          _other -> false
        end
    end)
  end

  defp final_response?(status), do: is_integer(status) and status >= 200

  defp validate_options(options) when is_list(options) do
    with true <- Keyword.keyword?(options),
         true <- Enum.all?(Keyword.keys(options), &(&1 in @allowed_options)),
         finch_name when is_atom(finch_name) <- Keyword.get(options, :finch_name),
         receive_timeout when is_integer(receive_timeout) and receive_timeout > 0 <-
           Keyword.get(options, :receive_timeout),
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

  defp validate_finch(finch_name) do
    if Process.whereis(finch_name), do: :ok, else: {:error, :connection_failed}
  end
end
