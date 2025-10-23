defmodule GSMLG.Socket.ErrorsTest do
  use ExUnit.Case, async: true
  doctest GSMLG.Socket.Errors

  alias GSMLG.Socket.Errors

  describe "categorize/2" do
    test "categorizes connection refused error" do
      error_info = Errors.categorize(:econnrefused, :tcp)

      assert error_info.category == :connection_refused
      assert error_info.socket_type == :tcp
      assert error_info.retryable == true
      assert is_binary(error_info.message)
      assert is_list(error_info.suggestions)
      assert length(error_info.suggestions) > 0
    end

    test "categorizes timeout error" do
      error_info = Errors.categorize(:timeout, :ssl)

      assert error_info.category == :timeout
      assert error_info.socket_type == :ssl
      assert error_info.retryable == true
    end

    test "categorizes SSL handshake failure" do
      error_info = Errors.categorize({:tls_alert, {:handshake_failure, "details"}}, :ssl)

      assert error_info.category == :ssl_error
      assert error_info.socket_type == :ssl
      assert error_info.retryable == false
    end

    test "categorizes certificate errors" do
      error_info = Errors.categorize({:tls_alert, {:bad_certificate, "details"}}, :ssl)

      assert error_info.category == :certificate_error
      assert error_info.retryable == false
    end

    test "categorizes WebSocket protocol error" do
      error_info = Errors.categorize(:protocol_error, :websocket)

      assert error_info.category == :protocol_error
      assert error_info.socket_type == :websocket
      assert error_info.retryable == false
    end

    test "categorizes unknown error" do
      error_info = Errors.categorize(:unknown_error_code, :tcp)

      assert error_info.category == :unknown
      assert error_info.retryable == false
    end
  end

  describe "format/1" do
    test "formats error info as string" do
      error_info = Errors.categorize(:econnrefused, :tcp)
      formatted = Errors.format(error_info)

      assert is_binary(formatted)
      assert formatted =~ "[TCP]"
      assert formatted =~ "Connection refused"
      assert formatted =~ "Suggestions:"
    end
  end

  describe "retryable?/2" do
    test "returns true for retryable errors" do
      assert Errors.retryable?(:timeout, :tcp) == true
      assert Errors.retryable?(:econnrefused, :tcp) == true
      assert Errors.retryable?(:ehostunreach, :tcp) == true
    end

    test "returns false for non-retryable errors" do
      assert Errors.retryable?(:einval, :tcp) == false
      assert Errors.retryable?(:nxdomain, :tcp) == false
      assert Errors.retryable?({:tls_alert, {:handshake_failure, ""}}, :ssl) == false
    end
  end
end
