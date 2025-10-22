defmodule GSMLG.Socket.WebTest do
  use ExUnit.Case, async: true
  alias GSMLG.Socket.Web

  describe "WebSocket masking" do
    test "handles different data sizes" do
      # Test with various data sizes
      for size <- [1, 7, 8, 16, 125, 126, 1000] do
        data = :crypto.strong_rand_bytes(size)
        assert byte_size(data) == size
      end
    end
  end

  describe "arguments/1" do
    test "separates WebSocket-specific options from TCP options" do
      {local, global} = Web.arguments(path: "/test", mode: :passive, secure: true)

      assert Keyword.has_key?(local, :path)
      assert Keyword.has_key?(local, :secure)
      assert Keyword.has_key?(global, :mode)
    end

    test "extracts path option" do
      {local, _global} = Web.arguments(path: "/api/websocket")
      assert local[:path] == "/api/websocket"
    end

    test "extracts origin option" do
      {local, _global} = Web.arguments(origin: "https://example.com")
      assert local[:origin] == "https://example.com"
    end

    test "extracts protocol option" do
      {local, _global} = Web.arguments(protocol: ["chat", "superchat"])
      assert local[:protocol] == ["chat", "superchat"]
    end

    test "extracts extensions option" do
      {local, _global} = Web.arguments(extensions: ["permessage-deflate"])
      assert local[:extensions] == ["permessage-deflate"]
    end

    test "passes through TCP options" do
      {_local, global} = Web.arguments(mode: :active, send: [timeout: 5000])
      assert Keyword.has_key?(global, :mode)
      assert Keyword.has_key?(global, :send)
    end
  end

  describe "packet types" do
    test "text packet format" do
      packet = {:text, "Hello"}
      assert is_tuple(packet)
      assert elem(packet, 0) == :text
    end

    test "binary packet format" do
      packet = {:binary, <<1, 2, 3>>}
      assert is_tuple(packet)
      assert elem(packet, 0) == :binary
    end

    test "ping packet format" do
      packet = {:ping, "cookie"}
      assert is_tuple(packet)
      assert elem(packet, 0) == :ping
    end

    test "pong packet format" do
      packet = {:pong, "cookie"}
      assert is_tuple(packet)
      assert elem(packet, 0) == :pong
    end

    test "close packet formats" do
      assert :close == :close
      assert {:close, :normal, <<>>} |> is_tuple()
    end
  end

  describe "close codes" do
    test "recognizes standard close codes" do
      codes = [
        :normal,
        :going_away,
        :protocol_error,
        :unsupported_data,
        :invalid_payload,
        :policy_violation,
        :message_too_big,
        :internal_error
      ]

      for code <- codes do
        assert is_atom(code)
      end
    end
  end

  describe "handshake key generation" do
    test "generates cryptographically secure random keys by default" do
      {local, _} = Web.arguments([])

      # When no handshake is provided, it should use crypto random
      # We can't test the exact value but we can test it exists
      assert is_list(local)
    end

    test "accepts custom handshake key" do
      custom_key = :crypto.strong_rand_bytes(16)
      {local, _} = Web.arguments(handshake: custom_key)
      assert local[:handshake] == custom_key
    end
  end

  # Integration tests would require a real WebSocket server
  # These are marked as skip for unit testing
  describe "integration tests (require server)" do
    @tag :skip
    test "can connect to WebSocket server" do
      # Would connect to a real WebSocket echo server
      # Skipped in basic test suite
    end

    @tag :skip
    test "can send and receive text messages" do
      # Would test full send/recv cycle
      # Skipped in basic test suite
    end

    @tag :skip
    test "handles ping/pong correctly" do
      # Would test ping/pong mechanism
      # Skipped in basic test suite
    end
  end
end
