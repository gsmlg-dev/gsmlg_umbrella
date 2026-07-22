defmodule GSMLG.ProxyRules.Transport.Finch do
  @moduledoc """
  Finch-backed streaming HTTP transport with a hard response-body limit.
  """

  @behaviour GSMLG.ProxyRules.Transport

  @allowed_options [:finch_name, :receive_timeout, :max_body_size]

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
    initial = %{status: nil, headers: [], body: [], body_size: 0, error: nil}

    result =
      Finch.stream_while(
        request,
        options[:finch_name],
        initial,
        &reduce_response(&1, &2, options[:max_body_size]),
        receive_timeout: options[:receive_timeout]
      )

    normalize_result(result)
  catch
    :exit, :timeout -> {:error, :timeout}
    :exit, {:timeout, _context} -> {:error, :timeout}
  end

  defp reduce_response({:status, status}, accumulator, _max_body_size),
    do: {:cont, %{accumulator | status: status}}

  defp reduce_response({:headers, headers}, accumulator, max_body_size) do
    accumulator = %{accumulator | headers: accumulator.headers ++ headers}

    if content_length_exceeds?(headers, max_body_size) do
      {:halt, %{accumulator | error: :body_too_large}}
    else
      {:cont, accumulator}
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

  defp normalize_result({:ok, %{status: status, headers: headers, body: body}})
       when is_integer(status) do
    {:ok,
     %{status: status, headers: headers, body: body |> Enum.reverse() |> IO.iodata_to_binary()}}
  end

  defp normalize_result({:ok, _accumulator}), do: {:error, :http_error}
  defp normalize_result({:error, error, _accumulator}), do: {:error, normalize_error(error)}

  defp normalize_error(%Finch.TransportError{reason: :timeout}), do: :receive_timeout

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
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             is_integer(port) and port > 0 and port <= 65_535 ->
        :ok

      _uri ->
        {:error, :invalid_url}
    end
  rescue
    ArgumentError -> {:error, :invalid_url}
  end

  defp validate_url(_url), do: {:error, :invalid_url}

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, fn
         {name, value} when is_binary(name) and is_binary(value) -> true
         _header -> false
       end),
       do: :ok,
       else: {:error, :invalid_headers}
  end

  defp validate_headers(_headers), do: {:error, :invalid_headers}

  defp validate_finch(finch_name) do
    if Process.whereis(finch_name), do: :ok, else: {:error, :connection_failed}
  end
end
