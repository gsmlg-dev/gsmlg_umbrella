defmodule GSMLG.Whois.WhoisProtocolTest do
  use ExUnit.Case, async: false

  alias GSMLG.Whois
  alias GSMLG.Whois.Server

  test "a silent peer times out and closes its socket" do
    parent = self()

    {server, _peer} =
      peer(fn socket ->
        assert {:ok, "example.com\r\n"} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :queried)
        send(parent, {:peer_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

    task =
      Task.async(fn ->
        Whois.lookup_raw("example.com", server: server, cache: false, timeout: 80)
      end)

    assert_receive :queried, 1_000
    assert {:ok, {:error, :timeout}} = Task.yield(task, 300) || Task.shutdown(task, :brutal_kill)
    assert_receive {:peer_closed, {:error, :closed}}, 1_000
  end

  test "deadline also bounds stalled native DNS resolution" do
    :inet.gethostbyname(~c"localhost")
    resolver = Process.whereis(:inet_gethost_native)
    assert is_pid(resolver)
    lookup = :inet_db.res_option(:lookup)
    :inet_db.set_lookup([:native])
    :erlang.suspend_process(resolver)

    try do
      task =
        Task.async(fn ->
          Whois.lookup_raw("example.com",
            server: "stalled-whois.invalid",
            cache: false,
            timeout: 80
          )
        end)

      assert {:ok, {:error, :timeout}} =
               Task.yield(task, 300) || Task.shutdown(task, :brutal_kill)
    after
      :erlang.resume_process(resolver)
      :inet_db.set_lookup(lookup)
    end
  end

  test "receiving data does not restart the deadline" do
    {server, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)

        for _ <- 1..20 do
          :gen_tcp.send(socket, "partial\r\n")
          Process.sleep(30)
        end
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Whois.lookup_raw("example.com", server: server, cache: false, timeout: 300)

    assert System.monotonic_time(:millisecond) - started < 500
  end

  test "referrals share the original deadline and propagate timeout" do
    parent = self()

    {referral, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, {:referral_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

    port = Map.fetch!(referral, :port)

    {server, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        Process.sleep(400)
        :gen_tcp.send(socket, "whois: 127.0.0.1:#{port}\r\n")
      end)

    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Whois.lookup_raw("example.com", server: server, cache: false, timeout: 600)

    assert System.monotonic_time(:millisecond) - started < 850
    assert_receive {:referral_closed, {:error, :closed}}, 1_000
  end

  test "cancelling the lookup task closes the socket" do
    parent = self()

    {server, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        send(parent, :queried)
        send(parent, {:cancelled_closed, :gen_tcp.recv(socket, 0, 1_000)})
      end)

    task =
      Task.async(fn ->
        Whois.lookup_raw("example.com", server: server, cache: false, timeout: 5_000)
      end)

    assert_receive :queried, 1_000
    Task.shutdown(task, :brutal_kill)
    assert_receive {:cancelled_closed, {:error, :closed}}, 1_000
  end

  for {query, type} <- [{"example.com", :domain}, {"8.8.8.8", :ip}, {"13335", :asn}] do
    test "preserves raw records for #{type} queries" do
      query = unquote(query)
      raw = "Registration for #{query}\r\nLast line without newline"
      parent = self()

      {server, _peer} =
        peer(fn socket ->
          {:ok, received} = :gen_tcp.recv(socket, 0, 1_000)
          send(parent, {:query, received})
          :gen_tcp.send(socket, raw)
        end)

      assert {:ok, [{"127.0.0.1", ^raw}]} =
               Whois.lookup_raw(query,
                 server: server,
                 cache: false,
                 type: unquote(type),
                 timeout: 500
               )

      assert_receive {:query, received}
      assert received == query <> "\r\n"
    end
  end

  test "returns successful referral records in root-first order" do
    raw = "Authoritative record\r\n"

    {referral, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.send(socket, raw)
      end)

    root_raw = "Registrar WHOIS Server: 127.0.0.1:#{Map.fetch!(referral, :port)}\r\n"

    {server, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.send(socket, root_raw)
      end)

    assert {:ok, [{"127.0.0.1", ^root_raw}, {"127.0.0.1", ^raw}]} =
             Whois.lookup_raw("example.com", server: server, cache: false, timeout: 500)
  end

  test "a peer that does not read a large query is bounded by the total deadline" do
    {server, _peer} = peer(fn _socket -> Process.sleep(800) end)
    query = String.duplicate("x", 8_000_000)
    started = System.monotonic_time(:millisecond)

    assert {:error, :timeout} =
             Whois.lookup_raw(query, server: server, cache: false, timeout: 200)

    assert System.monotonic_time(:millisecond) - started < 600
  end

  test "cyclic referrals remain bounded by the same deadline" do
    handler = fn socket ->
      {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)

      receive do
        {:refer_to, port} ->
          Process.sleep(20)
          :gen_tcp.send(socket, "whois: 127.0.0.1:#{port}\r\n")
      end
    end

    {first, first_peer} = peer(handler, 0, 20)
    {second, second_peer} = peer(handler, 0, 20)

    for _ <- 1..20 do
      send(first_peer, {:refer_to, second.port})
      send(second_peer, {:refer_to, first.port})
    end

    assert {:error, :timeout} =
             Whois.lookup_raw("example.com", server: first, cache: false, timeout: 150)
  end

  test "invalid referral ports keep the root record without crashing the caller" do
    raw = "whois: 127.0.0.1:99999\r\n"

    {server, _peer} =
      peer(fn socket ->
        {:ok, _query} = :gen_tcp.recv(socket, 0, 1_000)
        :gen_tcp.send(socket, raw)
      end)

    assert {:ok, [{"127.0.0.1", ^raw}]} =
             Whois.lookup_raw("example.com", server: server, cache: false, timeout: 500)
  end

  test "emits documented lookup lifecycle telemetry with query and type" do
    parent = self()
    handler = make_ref()
    events = [[:gsmlg, :whois, :lookup, :start], [:gsmlg, :whois, :lookup, :stop]]

    :telemetry.attach_many(
      handler,
      events,
      fn event, measurements, metadata, _ ->
        send(parent, {:lookup_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:error, :timeout} = Whois.lookup_raw("example.com", cache: false, timeout: 0)

    assert_receive {:lookup_event, [:gsmlg, :whois, :lookup, :start], _,
                    %{query: "example.com", type: :domain}}

    assert_receive {:lookup_event, [:gsmlg, :whois, :lookup, :stop], %{duration: duration},
                    %{query: "example.com", type: :domain}}

    assert duration >= 0
  end

  test "zero deadline does not open a connection" do
    {server, _peer} = peer(fn _socket -> flunk("expired lookup opened a connection") end)

    assert {:error, :timeout} =
             Whois.lookup_raw("example.com", server: server, cache: false, timeout: 0)
  end

  defp peer(handler, port \\ 0, connections \\ 1) do
    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        active: false,
        packet: :line,
        ip: {127, 0, 0, 1},
        reuseaddr: true
      ])

    {:ok, {_, port}} = :inet.sockname(listener)

    peer =
      spawn_link(fn ->
        for _ <- 1..connections do
          case :gen_tcp.accept(listener) do
            {:ok, socket} ->
              try do
                handler.(socket)
              after
                :gen_tcp.close(socket)
              end

            {:error, :closed} ->
              :ok
          end
        end
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      if Process.alive?(peer), do: Process.exit(peer, :kill)
    end)

    {%Server{host: "127.0.0.1", port: port}, peer}
  end
end
