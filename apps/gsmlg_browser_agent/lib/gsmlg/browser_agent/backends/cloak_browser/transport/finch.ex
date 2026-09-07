defmodule GSMLG.BrowserAgent.Backends.CloakBrowser.Transport.Finch do
  @moduledoc false

  @behaviour GSMLG.BrowserAgent.Backends.CloakBrowser.Transport

  @max_header_bytes 65_536

  @impl true
  def request(method, url, headers, body, options) do
    request = Finch.build(method, url, headers, body)
    max_body_bytes = Keyword.fetch!(options, :max_body_bytes)

    result =
      Finch.stream_while(
        request,
        Keyword.get(options, :finch_name, GSMLG.BrowserAgent.Finch),
        initial_accumulator(),
        &reduce_response(&1, &2, max_body_bytes),
        pool_timeout: Keyword.fetch!(options, :connect_timeout),
        receive_timeout: Keyword.fetch!(options, :receive_timeout),
        request_timeout: Keyword.fetch!(options, :receive_timeout)
      )

    normalize_result(result)
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

  defp normalize_result({:ok, %{error: reason}}) when is_atom(reason) and not is_nil(reason),
    do: {:error, reason}

  defp normalize_result({:ok, %{status: status, body: chunks}}) when is_integer(status) do
    {:ok, %{status: status, body: chunks |> Enum.reverse() |> IO.iodata_to_binary()}}
  end

  defp normalize_result({:ok, _state}), do: {:error, :invalid_response}
  defp normalize_result({:error, error, _state}), do: {:error, normalize_error(error)}

  defp normalize_error(%Finch.TransportError{reason: :timeout}), do: :timeout
  defp normalize_error(%Finch.Error{reason: :request_timeout}), do: :timeout
  defp normalize_error(_error), do: :connection_failed

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
