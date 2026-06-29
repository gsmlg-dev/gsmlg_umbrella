defmodule GSMLG.Scout.Agent.RedirectGuard do
  @moduledoc """
  Fetches Scout pages while validating each HTTP redirect target.
  """

  @callback fetch(String.t(), map(), non_neg_integer()) :: {:ok, map()} | {:error, map()}

  def fetch(url, settings, timeout_ms) do
    adapter().fetch(url, settings, timeout_ms)
  end

  defp adapter do
    Application.get_env(:gsmlg_scout_agent, :redirect_guard, __MODULE__.HTTP)
  end
end

defmodule GSMLG.Scout.Agent.RedirectGuard.HTTP do
  @moduledoc false

  @behaviour GSMLG.Scout.Agent.RedirectGuard

  alias GSMLG.Scout.Security

  @redirect_statuses 300..399

  @impl true
  def fetch(url, settings, timeout_ms) do
    deadline = deadline(timeout_ms)

    with :ok <- Security.validate_url(url, settings) do
      fetch_redirect_chain(url, settings, redirect_limit(settings), deadline)
    end
  end

  defp fetch_redirect_chain(_url, _settings, remaining, _deadline) when remaining < 0 do
    {:error,
     %{
       type: "redirect_limit_exceeded",
       message: "Scout redirect limit was exceeded",
       retryable: false
     }}
  end

  defp fetch_redirect_chain(url, settings, remaining, deadline) do
    with {:ok, response} <- request_without_redirect(url, settings, deadline) do
      status = response.status_code

      if redirect_status?(status) do
        with {:ok, target_url} <- redirect_target(url, response.headers),
             :ok <- Security.validate_url(target_url, settings) do
          fetch_redirect_chain(target_url, settings, remaining - 1, deadline)
        else
          {:error, %{type: _type} = error} ->
            {:error,
             %{
               error
               | message: "redirect target failed Scout security validation: #{error.message}",
                 retryable: false
             }}
        end
      else
        {:ok, Map.put(response, :final_url, url)}
      end
    end
  end

  defp request_without_redirect(url, settings, deadline) do
    with {:ok, timeout_ms} <- remaining_timeout(deadline) do
      do_request_without_redirect(url, settings, timeout_ms, deadline)
    end
  end

  defp do_request_without_redirect(url, settings, timeout_ms, deadline) do
    result =
      with {:ok, target} <- connect_target(url, settings),
           {:ok, transport} <- connect(target, timeout_ms) do
        try do
          request_via_transport(transport, target, settings, deadline)
        after
          close(transport)
        end
      end

    normalize_request_result(result)
  end

  defp request_via_transport(transport, target, settings, deadline) do
    with :ok <- send_request(transport, target),
         {:ok, status, headers} <- read_response_headers(transport, deadline),
         :ok <- set_raw_mode(transport) do
      if redirect_status?(status) do
        {:ok,
         %{status_code: status, headers: headers, content_type: content_type(headers), body: ""}}
      else
        with :ok <- validate_content_length(headers, settings),
             {:ok, body} <- read_body(transport, headers, settings, deadline) do
          {:ok,
           %{
             status_code: status,
             headers: headers,
             content_type: content_type(headers),
             body: body
           }}
        end
      end
    end
  end

  defp normalize_request_result({:error, %{type: _type}} = error), do: error

  defp normalize_request_result({:error, reason}) do
    {:error,
     %{
       type: "redirect_check_failed",
       message: "Scout redirect validation failed: #{inspect(reason)}",
       retryable: true
     }}
  end

  defp normalize_request_result(result), do: result

  defp redirect_status?(status), do: status in @redirect_statuses

  defp redirect_target(url, headers) do
    case header(headers, ~c"location") do
      nil ->
        {:error,
         %{
           type: "invalid_redirect",
           message: "redirect response did not include a location",
           retryable: false
         }}

      location ->
        {:ok, URI.merge(url, to_string(location)) |> URI.to_string()}
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == to_string(name), do: value
    end)
  end

  defp connect_target(url, settings) do
    with {:ok, uri} <- URI.new(url),
         {:ok, addresses} <- resolve_addresses(uri.host),
         :ok <- validate_addresses(uri, addresses, settings) do
      {:ok,
       %{
         uri: uri,
         address: List.first(addresses),
         host: uri.host,
         port: uri.port || default_port(uri.scheme),
         scheme: uri.scheme
       }}
    end
  end

  defp resolve_addresses(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, :einval} ->
        resolver = Application.get_env(:gsmlg_scout, :dns_resolver, :inet)
        charlist_host = String.to_charlist(host)

        addresses =
          [:inet, :inet6]
          |> Enum.flat_map(fn family ->
            case resolver.getaddrs(charlist_host, family) do
              {:ok, resolved} -> resolved
              _error -> []
            end
          end)

        if addresses == [] do
          {:error,
           %{
             type: "unresolvable_host",
             message: "url host could not be resolved",
             retryable: true
           }}
        else
          {:ok, addresses}
        end
    end
  rescue
    exception ->
      {:error,
       %{
         type: "unresolvable_host",
         message: "url host could not be resolved: #{Exception.message(exception)}",
         retryable: true
       }}
  catch
    _kind, reason ->
      {:error,
       %{
         type: "unresolvable_host",
         message: "url host could not be resolved: #{inspect(reason)}",
         retryable: true
       }}
  end

  defp validate_addresses(uri, addresses, settings) do
    Enum.reduce_while(addresses, :ok, fn address, :ok ->
      case Security.validate_url(url_with_address(uri, address), settings) do
        :ok -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp url_with_address(uri, address) do
    host = address_host(address)
    path = uri.path || "/"
    query = if uri.query, do: "?#{uri.query}", else: ""
    port = uri.port || default_port(uri.scheme)
    "#{uri.scheme}://#{host}:#{port}#{path}#{query}"
  end

  defp address_host({_, _, _, _} = address), do: address |> :inet.ntoa() |> to_string()
  defp address_host(address), do: "[#{address |> :inet.ntoa() |> to_string()}]"

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443

  defp connect(%{scheme: "http", address: address, port: port}, timeout_ms) do
    with {:ok, socket} <-
           :gen_tcp.connect(
             address,
             port,
             [:binary, packet: :line, active: false, recbuf: 8_192],
             timeout_ms
           ) do
      {:ok, {:tcp, socket}}
    end
  end

  defp connect(%{scheme: "https", address: address, host: host, port: port}, timeout_ms) do
    opts = [
      :binary,
      packet: :line,
      active: false,
      recbuf: 8_192,
      server_name_indication: String.to_charlist(host),
      verify: :verify_none
    ]

    with {:ok, socket} <- :ssl.connect(address, port, opts, timeout_ms) do
      {:ok, {:ssl, socket}}
    end
  end

  defp connect(_target, _timeout_ms) do
    {:error,
     %{
       type: "unsupported_protocol",
       message: "only HTTP and HTTPS URLs are supported",
       retryable: false
     }}
  end

  defp send_request(transport, target) do
    request = [
      "GET ",
      request_target(target.uri),
      " HTTP/1.0\r\n",
      "host: ",
      host_header(target),
      "\r\n",
      "user-agent: GSMLG Scout\r\n",
      "accept: */*\r\n",
      "accept-encoding: identity\r\n",
      "connection: close\r\n\r\n"
    ]

    send_data(transport, request)
  end

  defp request_target(uri) do
    path = uri.path || "/"
    if uri.query, do: "#{path}?#{uri.query}", else: path
  end

  defp host_header(%{host: host, port: port, scheme: scheme}) do
    if port == default_port(scheme), do: host, else: "#{host}:#{port}"
  end

  defp read_response_headers(transport, deadline) do
    with {:ok, status_line} <- recv_line(transport, deadline),
         {:ok, status} <- parse_status(status_line),
         {:ok, headers} <- read_header_lines(transport, deadline, [], byte_size(status_line)) do
      {:ok, status, headers}
    end
  end

  defp parse_status(line) do
    case String.split(String.trim(line), " ", parts: 3) do
      ["HTTP/" <> _version, status, _reason] ->
        case Integer.parse(status) do
          {status_code, ""} -> {:ok, status_code}
          _invalid -> {:error, :invalid_status}
        end

      _invalid ->
        {:error, :invalid_status}
    end
  end

  defp read_header_lines(_transport, _deadline, _headers, size) when size > 65_536 do
    {:error,
     %{
       type: "headers_too_large",
       message: "response headers exceeded Scout header size limit",
       retryable: false
     }}
  end

  defp read_header_lines(transport, deadline, headers, size) do
    with {:ok, line} <- recv_line(transport, deadline) do
      if line in ["\r\n", "\n"] do
        {:ok, Enum.reverse(headers)}
      else
        read_header_lines(
          transport,
          deadline,
          [parse_header(line) | headers],
          size + byte_size(line)
        )
      end
    end
  end

  defp parse_header(line) do
    case String.split(String.trim_trailing(line), ":", parts: 2) do
      [name, value] -> {String.downcase(String.trim(name)), String.trim(value)}
      [name] -> {String.downcase(String.trim(name)), ""}
    end
  end

  defp set_raw_mode({:tcp, socket}), do: :inet.setopts(socket, packet: :raw)
  defp set_raw_mode({:ssl, socket}), do: :ssl.setopts(socket, packet: :raw)

  defp read_body(transport, headers, settings, deadline) do
    case content_length(headers) do
      {:ok, length} ->
        read_body_until(transport, settings, deadline, length, [], 0)

      :unknown ->
        read_body_until_close(transport, settings, deadline, [], 0)
    end
  end

  defp content_length(headers) do
    case header(headers, ~c"content-length") do
      nil ->
        :unknown

      value ->
        case Integer.parse(to_string(value)) do
          {length, ""} when length >= 0 -> {:ok, length}
          _invalid -> :unknown
        end
    end
  end

  defp read_body_until(_transport, _settings, _deadline, 0, chunks, _size) do
    {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp read_body_until(transport, settings, deadline, remaining, chunks, size) do
    read_size = min(remaining, 8_192)

    with {:ok, chunk} <- recv(transport, read_size, deadline) do
      size = size + byte_size(chunk)

      if size > max_page_size(settings) do
        page_too_large_error()
      else
        read_body_until(
          transport,
          settings,
          deadline,
          remaining - byte_size(chunk),
          [chunk | chunks],
          size
        )
      end
    end
  end

  defp read_body_until_close(transport, settings, deadline, chunks, size) do
    case recv(transport, 0, deadline) do
      {:ok, chunk} ->
        size = size + byte_size(chunk)

        if size > max_page_size(settings) do
          page_too_large_error()
        else
          read_body_until_close(transport, settings, deadline, [chunk | chunks], size)
        end

      {:error, :closed} ->
        {:ok, chunks |> Enum.reverse() |> IO.iodata_to_binary()}

      {:error, %{type: _type}} = error ->
        error

      {:error, reason} ->
        {:error,
         %{
           type: "redirect_check_failed",
           message: "Scout redirect validation failed: #{inspect(reason)}",
           retryable: true
         }}
    end
  end

  defp recv_line(transport, deadline), do: recv(transport, 0, deadline)

  defp recv(transport, length, deadline) do
    case remaining_timeout(deadline) do
      {:ok, timeout} -> recv_data(transport, length, timeout)
      {:error, _error} = error -> error
    end
  end

  defp send_data({:tcp, socket}, data), do: :gen_tcp.send(socket, data)
  defp send_data({:ssl, socket}, data), do: :ssl.send(socket, data)

  defp recv_data({:tcp, socket}, length, timeout), do: :gen_tcp.recv(socket, length, timeout)
  defp recv_data({:ssl, socket}, length, timeout), do: :ssl.recv(socket, length, timeout)

  defp close({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close({:ssl, socket}), do: :ssl.close(socket)

  defp content_type(headers) do
    case header(headers, ~c"content-type") do
      nil -> "text/html; charset=utf-8"
      value -> to_string(value)
    end
  end

  defp redirect_limit(settings) do
    settings
    |> get_in(["security", "redirect_limit"])
    |> case do
      value when is_integer(value) -> value
      _value -> 5
    end
  end

  defp validate_content_length(headers, settings) do
    case header(headers, ~c"content-length") do
      nil ->
        :ok

      value ->
        max_size = max_page_size(settings)

        case Integer.parse(to_string(value)) do
          {length, ""} when length <= max_size -> :ok
          {_length, ""} -> page_too_large_error()
          _invalid -> :ok
        end
    end
  end

  defp max_page_size(settings) do
    settings
    |> get_in(["fetch", "max_page_size_bytes"])
    |> case do
      value when is_integer(value) and value > 0 -> value
      _value -> 5_000_000
    end
  end

  defp page_too_large_error do
    {:error,
     %{
       type: "page_too_large",
       message: "fetched page exceeded Scout page size limit",
       retryable: false
     }}
  end

  defp deadline(timeout_ms), do: System.monotonic_time(:millisecond) + timeout_ms

  defp remaining_timeout(deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining > 0 do
      {:ok, remaining}
    else
      timeout_error()
    end
  end

  defp timeout_error do
    {:error, %{type: "timeout", message: "fetch timed out", retryable: true}}
  end
end
