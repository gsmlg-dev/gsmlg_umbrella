defmodule GSMLG.Socket.Errors do
  @moduledoc """
  Enhanced error types and error handling utilities for GSMLG.Socket.

  This module provides structured error information to help with debugging
  and error handling in production systems.

  ## Error Categories

  - **Connection Errors** - Failed to establish connection
  - **Security Errors** - SSL/TLS related failures
  - **Protocol Errors** - WebSocket or other protocol violations
  - **Timeout Errors** - Operations that exceeded time limits
  - **Data Errors** - Invalid data or payload issues

  ## Example Usage

      case GSMLG.Socket.TCP.connect("example.com", 80) do
        {:ok, socket} ->
          # handle success
        {:error, reason} ->
          error_info = GSMLG.Socket.Errors.categorize(reason, :tcp)
          IO.inspect(error_info)
      end
  """

  @type error_category ::
          :connection_refused
          | :timeout
          | :network_unreachable
          | :ssl_error
          | :certificate_error
          | :protocol_error
          | :invalid_data
          | :unknown

  @type error_info :: %{
          category: error_category(),
          original_reason: term(),
          message: String.t(),
          socket_type: atom(),
          retryable: boolean(),
          suggestions: [String.t()]
        }

  @doc """
  Categorize an error and provide structured information.

  Returns a map with detailed error information including:
  - category: The error category
  - message: Human-readable error message
  - retryable: Whether the operation can be retried
  - suggestions: List of potential solutions

  ## Examples

      iex> error_info = GSMLG.Socket.Errors.categorize(:econnrefused, :tcp)
      iex> error_info.category
      :connection_refused
      iex> error_info.retryable
      true
  """
  @spec categorize(term(), atom()) :: error_info()
  def categorize(reason, socket_type \\ :tcp)

  # Connection errors
  def categorize(:econnrefused, socket_type) do
    %{
      category: :connection_refused,
      original_reason: :econnrefused,
      message: "Connection refused - the remote server is not accepting connections",
      socket_type: socket_type,
      retryable: true,
      suggestions: [
        "Check if the server is running",
        "Verify the port number is correct",
        "Check firewall rules",
        "Verify the service is listening on the expected interface"
      ]
    }
  end

  def categorize(:timeout, socket_type) do
    %{
      category: :timeout,
      original_reason: :timeout,
      message: "Operation timed out - no response within the specified time",
      socket_type: socket_type,
      retryable: true,
      suggestions: [
        "Increase the timeout value",
        "Check network connectivity",
        "Verify the remote server is responsive",
        "Check for network congestion"
      ]
    }
  end

  def categorize(:ehostunreach, socket_type) do
    %{
      category: :network_unreachable,
      original_reason: :ehostunreach,
      message: "Host unreachable - network routing problem",
      socket_type: socket_type,
      retryable: true,
      suggestions: [
        "Check network connectivity",
        "Verify DNS resolution",
        "Check routing tables",
        "Verify the host address is correct"
      ]
    }
  end

  def categorize(:enetunreach, socket_type) do
    %{
      category: :network_unreachable,
      original_reason: :enetunreach,
      message: "Network unreachable - cannot reach the network",
      socket_type: socket_type,
      retryable: true,
      suggestions: [
        "Check network interface is up",
        "Verify network configuration",
        "Check default gateway",
        "Verify VPN connection if applicable"
      ]
    }
  end

  def categorize(:nxdomain, socket_type) do
    %{
      category: :network_unreachable,
      original_reason: :nxdomain,
      message: "DNS resolution failed - domain does not exist",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Verify the hostname is correct",
        "Check DNS server configuration",
        "Try using IP address instead of hostname",
        "Check for typos in the domain name"
      ]
    }
  end

  # SSL/TLS errors
  def categorize({:tls_alert, {:handshake_failure, _}}, socket_type) do
    %{
      category: :ssl_error,
      original_reason: {:tls_alert, :handshake_failure},
      message: "SSL/TLS handshake failed - incompatible cipher suites or protocol versions",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Check TLS version compatibility (server may not support TLS 1.2+)",
        "Verify cipher suite compatibility",
        "Check server SSL/TLS configuration",
        "Review client SSL options"
      ]
    }
  end

  def categorize({:tls_alert, {:certificate_unknown, _}}, socket_type) do
    %{
      category: :certificate_error,
      original_reason: {:tls_alert, :certificate_unknown},
      message: "Certificate verification failed - certificate not recognized",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Check if certificate is self-signed",
        "Verify CA certificate bundle is up to date",
        "Check certificate chain completeness",
        "Verify certificate is valid for the domain"
      ]
    }
  end

  def categorize({:tls_alert, {:bad_certificate, _}}, socket_type) do
    %{
      category: :certificate_error,
      original_reason: {:tls_alert, :bad_certificate},
      message: "Bad certificate - certificate is corrupted or invalid",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Check certificate file integrity",
        "Verify certificate format (PEM/DER)",
        "Regenerate certificate if corrupted",
        "Check certificate expiration date"
      ]
    }
  end

  def categorize({:tls_alert, {:certificate_expired, _}}, socket_type) do
    %{
      category: :certificate_error,
      original_reason: {:tls_alert, :certificate_expired},
      message: "Certificate expired - the certificate is no longer valid",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Renew the certificate",
        "Check system clock is correct",
        "Verify certificate validity period",
        "Contact server administrator"
      ]
    }
  end

  def categorize({:tls_alert, alert}, socket_type) when is_tuple(alert) do
    {alert_type, _} = alert

    %{
      category: :ssl_error,
      original_reason: {:tls_alert, alert_type},
      message: "SSL/TLS alert: #{alert_type}",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Review SSL/TLS configuration",
        "Check server logs for details",
        "Verify protocol compatibility"
      ]
    }
  end

  # WebSocket errors
  def categorize(:protocol_error, :websocket) do
    %{
      category: :protocol_error,
      original_reason: :protocol_error,
      message: "WebSocket protocol violation - invalid frame received",
      socket_type: :websocket,
      retryable: false,
      suggestions: [
        "Check WebSocket frame format",
        "Verify client/server WebSocket version compatibility",
        "Check for data corruption",
        "Review WebSocket implementation"
      ]
    }
  end

  def categorize(:invalid_payload, :websocket) do
    %{
      category: :invalid_data,
      original_reason: :invalid_payload,
      message: "Invalid WebSocket payload - data is malformed or not UTF-8",
      socket_type: :websocket,
      retryable: false,
      suggestions: [
        "Verify text frames contain valid UTF-8",
        "Use binary frames for non-text data",
        "Check data encoding before sending"
      ]
    }
  end

  # Generic errors
  def categorize(:closed, socket_type) do
    %{
      category: :connection_refused,
      original_reason: :closed,
      message: "Connection closed - the socket was closed",
      socket_type: socket_type,
      retryable: true,
      suggestions: [
        "Re-establish connection",
        "Check if remote closed connection gracefully",
        "Implement reconnection logic"
      ]
    }
  end

  def categorize(:einval, socket_type) do
    %{
      category: :invalid_data,
      original_reason: :einval,
      message: "Invalid argument - operation parameters are incorrect",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Verify function arguments",
        "Check socket options validity",
        "Review API documentation"
      ]
    }
  end

  # Fallback for unknown errors
  def categorize(reason, socket_type) do
    %{
      category: :unknown,
      original_reason: reason,
      message: "Unknown error: #{inspect(reason)}",
      socket_type: socket_type,
      retryable: false,
      suggestions: [
        "Check application logs for details",
        "Review error reason: #{inspect(reason)}",
        "Consult documentation or support"
      ]
    }
  end

  @doc """
  Format an error for logging or display.

  Returns a formatted string with error details.

  ## Example

      iex> error_info = GSMLG.Socket.Errors.categorize(:econnrefused, :tcp)
      iex> GSMLG.Socket.Errors.format(error_info)
      "[TCP] Connection refused - the remote server is not accepting connections\\nSuggestions:\\n  - Check if the server is running\\n  - ..."
  """
  @spec format(error_info()) :: String.t()
  def format(%{message: message, socket_type: socket_type, suggestions: suggestions}) do
    type_str = socket_type |> to_string() |> String.upcase()
    suggestions_str = Enum.map_join(suggestions, "\n  - ", & &1)

    "[#{type_str}] #{message}\nSuggestions:\n  - #{suggestions_str}"
  end

  @doc """
  Check if an error is retryable.

  Returns true if the operation can be retried with a chance of success.

  ## Example

      iex> GSMLG.Socket.Errors.retryable?(:timeout, :tcp)
      true

      iex> GSMLG.Socket.Errors.retryable?(:einval, :tcp)
      false
  """
  @spec retryable?(term(), atom()) :: boolean()
  def retryable?(reason, socket_type) do
    categorize(reason, socket_type).retryable
  end
end
