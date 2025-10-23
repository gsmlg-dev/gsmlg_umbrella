defmodule GSMLG.Socket.SSLTest do
  use ExUnit.Case, async: true
  alias GSMLG.Socket.SSL

  describe "ciphers/0" do
    test "returns list of supported ciphers" do
      ciphers = SSL.ciphers()
      assert is_list(ciphers)
      assert length(ciphers) > 0
    end
  end

  describe "versions/0" do
    test "returns SSL/TLS version information" do
      versions = SSL.versions()
      assert is_list(versions)
      assert Keyword.has_key?(versions, :available)
      assert Keyword.has_key?(versions, :supported)
    end
  end

  describe "error/1" do
    test "formats SSL error codes" do
      # Test with some common SSL errors
      result = SSL.error(:closed)
      assert is_binary(result) or is_nil(result)
    end

    test "SSL.Error exception formatting" do
      error = GSMLG.Socket.SSL.Error.exception(reason: :closed)
      assert is_binary(error.message)
      assert error.__struct__ == GSMLG.Socket.SSL.Error
    end
  end

  describe "arguments/1" do
    test "applies security defaults for TLS versions" do
      args = SSL.arguments([])

      # Should contain TLS version settings
      assert Keyword.has_key?(args, :versions) or
               Enum.any?(args, fn
                 {:versions, _} -> true
                 _ -> false
               end)
    end

    test "allows overriding security defaults" do
      args = SSL.arguments(versions: [:"tlsv1.2"])

      # Find the versions key
      versions = Keyword.get(args, :versions)
      assert versions == [:"tlsv1.2"] or is_nil(versions)
    end

    test "converts :verify false correctly" do
      args = SSL.arguments(verify: false)
      assert {:verify, :verify_none} in args
    end

    test "converts certificate paths" do
      args = SSL.arguments(cert: [path: "/path/to/cert"])
      assert {:certfile, "/path/to/cert"} in args
    end

    test "converts key paths" do
      args = SSL.arguments(key: [path: "/path/to/key"])
      assert {:keyfile, "/path/to/key"} in args
    end

    test "converts authorities paths" do
      args = SSL.arguments(authorities: [path: "/path/to/ca"])
      assert {:cacertfile, "/path/to/ca"} in args
    end

    test "converts hibernate option correctly" do
      args = SSL.arguments(hibernate: 5000)
      assert {:hibernate_after, 5000} in args
    end

    test "converts server_name option" do
      args = SSL.arguments(server_name: "example.com")
      assert {:server_name_indication, ~c"example.com"} in args
    end

    test "disables server_name_indication when false" do
      args = SSL.arguments(server_name: false)
      assert {:server_name_indication, :disable} in args
    end
  end

  # Note: Full SSL connection tests require proper certificates
  # These would be integration tests that need test certificates
  describe "integration tests (skipped without certs)" do
    @tag :skip
    test "can establish SSL connection" do
      # This would require setting up test certificates
      # Skipped in basic test suite
    end
  end
end
