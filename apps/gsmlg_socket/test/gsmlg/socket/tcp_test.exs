defmodule GSMLG.Socket.TCPTest do
  use ExUnit.Case, async: true
  alias GSMLG.Socket.TCP

  describe "listen/2 and accept/2" do
    test "can create a listening socket on a random port" do
      assert {:ok, server} = TCP.listen()
      assert {:ok, {_address, port}} = GSMLG.Socket.local(server)
      assert is_integer(port)
      assert port > 0
      :gen_tcp.close(server)
    end

    test "can listen on a specific port" do
      port = 50000 + :rand.uniform(10000)
      assert {:ok, server} = TCP.listen(port)
      assert {:ok, {_address, ^port}} = GSMLG.Socket.local(server)
      :gen_tcp.close(server)
    end

    test "accept times out when no connection is made" do
      {:ok, server} = TCP.listen()
      assert {:error, :timeout} = TCP.accept(server, timeout: 100)
      :gen_tcp.close(server)
    end

    test "can accept a client connection" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      # Connect in a separate process
      task =
        Task.async(fn ->
          TCP.connect("127.0.0.1", port)
        end)

      assert {:ok, client} = TCP.accept(server, timeout: 1000)
      assert {:ok, _connected_client} = Task.await(task)

      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end

    test "setopts error handling on accept" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      task =
        Task.async(fn ->
          TCP.connect("127.0.0.1", port)
        end)

      # Accept with valid mode option
      assert {:ok, client} = TCP.accept(server, mode: :passive, timeout: 1000)
      {:ok, _} = Task.await(task)

      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
  end

  describe "connect/3" do
    test "can connect to a server" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      task =
        Task.async(fn ->
          TCP.accept(server)
        end)

      assert {:ok, client} = TCP.connect("127.0.0.1", port)
      {:ok, accepted} = Task.await(task)

      :gen_tcp.close(client)
      :gen_tcp.close(accepted)
      :gen_tcp.close(server)
    end

    test "connect fails with invalid address" do
      assert {:error, _reason} = TCP.connect("0.0.0.0", 1, timeout: 100)
    end
  end

  describe "send and recv" do
    test "can send and receive data" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      # Use a receive task that waits for data
      recv_task =
        Task.async(fn ->
          {:ok, server_client} = TCP.accept(server, mode: :passive)
          # Wait for data
          result = GSMLG.Socket.Stream.recv(server_client, timeout: 2000)
          :gen_tcp.close(server_client)
          result
        end)

      # Connect and send
      {:ok, client} = TCP.connect("127.0.0.1", port, mode: :passive)
      message = "Hello, World!"
      assert :ok = GSMLG.Socket.Stream.send(client, message)

      # Wait for receive to complete
      assert {:ok, ^message} = Task.await(recv_task, 3000)

      # Clean up
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end

    test "recv returns nil on closed connection" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      accept_task =
        Task.async(fn ->
          TCP.accept(server, mode: :passive)
        end)

      {:ok, client} = TCP.connect("127.0.0.1", port, mode: :passive)
      {:ok, server_client} = Task.await(accept_task)

      # Close client
      :gen_tcp.close(client)

      # Server should get nil on closed connection
      assert {:ok, nil} = GSMLG.Socket.Stream.recv(server_client, timeout: 500)

      :gen_tcp.close(server_client)
      :gen_tcp.close(server)
    end
  end

  describe "error handling" do
    test "TCP.Error exception formatting" do
      error = GSMLG.Socket.TCP.Error.exception(reason: :econnrefused)
      assert error.message =~ "connection refused"
      assert error.__struct__ == GSMLG.Socket.TCP.Error
    end

    test "error/1 returns formatted error messages" do
      assert TCP.error(:econnrefused) =~ "connection refused"
      assert TCP.error(:timeout) =~ "timeout"
    end
  end

  describe "options/2" do
    test "can set socket options" do
      {:ok, server} = TCP.listen()
      assert :ok = TCP.options(server, mode: :passive)
      :gen_tcp.close(server)
    end
  end

  describe "process/2" do
    test "can change controlling process" do
      {:ok, server} = TCP.listen()
      {:ok, {_address, port}} = GSMLG.Socket.local(server)

      {:ok, client} = TCP.connect("127.0.0.1", port)

      # Get the PID for the new controlling process
      new_owner =
        spawn(fn ->
          receive do
            :done -> :ok
          end
        end)

      assert :ok = TCP.process(client, new_owner)

      send(new_owner, :done)
      :gen_tcp.close(client)
      :gen_tcp.close(server)
    end
  end
end
