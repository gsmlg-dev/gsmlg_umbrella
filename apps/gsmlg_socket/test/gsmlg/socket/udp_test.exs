defmodule GSMLG.Socket.UDPTest do
  use ExUnit.Case, async: true
  alias GSMLG.Socket.UDP

  describe "open/2" do
    test "can open a UDP socket on a random port" do
      assert {:ok, socket} = UDP.open()
      assert {:ok, {_address, port}} = GSMLG.Socket.local(socket)
      assert is_integer(port)
      assert port > 0
      :gen_udp.close(socket)
    end

    test "can open on a specific port" do
      port = 50000 + :rand.uniform(10000)
      assert {:ok, socket} = UDP.open(port)
      assert {:ok, {_address, ^port}} = GSMLG.Socket.local(socket)
      :gen_udp.close(socket)
    end

    test "can open with options" do
      assert {:ok, socket} = UDP.open(mode: :passive, as: :binary)
      :gen_udp.close(socket)
    end
  end

  describe "send and recv" do
    test "can send and receive UDP packets" do
      {:ok, server} = UDP.open()
      {:ok, {_address, server_port}} = GSMLG.Socket.local(server)

      {:ok, client} = UDP.open()

      message = "Hello, UDP!"
      assert :ok = GSMLG.Socket.Datagram.send(client, message, {"127.0.0.1", server_port})

      assert {:ok, {^message, {_client_addr, _client_port}}} =
               GSMLG.Socket.Datagram.recv(server, timeout: 1000)

      :gen_udp.close(client)
      :gen_udp.close(server)
    end

    test "recv times out when no data available" do
      {:ok, socket} = UDP.open()
      assert {:error, :timeout} = GSMLG.Socket.Datagram.recv(socket, timeout: 100)
      :gen_udp.close(socket)
    end
  end

  describe "options" do
    test "can set socket options" do
      {:ok, socket} = UDP.open()
      assert :ok = UDP.options(socket, mode: :passive)
      :gen_udp.close(socket)
    end

    test "supports broadcast option" do
      assert {:ok, socket} = UDP.open(broadcast: true)
      :gen_udp.close(socket)
    end
  end

  describe "process/2" do
    test "can change controlling process" do
      {:ok, socket} = UDP.open()

      # Get the PID for the new controlling process
      new_owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      assert :ok = UDP.process(socket, new_owner)

      send(new_owner, :done)
      :gen_udp.close(socket)
    end
  end
end
