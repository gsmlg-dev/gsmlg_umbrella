defmodule GSMLG.AdminWeb.NoteSyncWebSocketTest do
  use GSMLG.AdminWeb.ChannelCase, async: false
  import Bitwise
  alias GSMLG.GaoNote.{Compat, Label, Note, Sync}
  alias GSMLG.GaoNote.Sync.Protocol

  setup context do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)

    Application.put_env(:gsmlg_gao_note, :note_sync, %{
      enabled: true,
      ssh_enabled: true,
      trusted_proxy_ips: ["127.0.0.1"],
      max_blob_bytes: 536_870_912
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    fingerprint = Protocol.sha256(Ecto.UUID.generate())

    attrs = %{
      node_id: Ecto.UUID.generate(),
      actor_id: "websocket-peer",
      allowed_selectors: ["project=bear_note"]
    }

    {peer, endpoint, socket_module, headers} =
      if context[:transport] == :ssh do
        {:ok, peer} = Sync.register_ssh_peer(attrs)
        {peer, GSMLG.AdminWeb.NoteSyncSSHEndpoint, GSMLG.AdminWeb.NoteSyncSSHSocket, []}
      else
        {:ok, peer} = Sync.register_peer(Map.put(attrs, :certificate_fingerprint, fingerprint))

        {peer, GSMLG.AdminWeb.Endpoint, GSMLG.AdminWeb.NoteSyncSocket,
         [{"X-Note-Sync-Client-Fingerprint", fingerprint}]}
      end

    listener = start_supervised!({Bandit, plug: endpoint, ip: {127, 0, 0, 1}, port: 0})
    assert {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    %{
      fingerprint: fingerprint,
      peer: peer,
      port: port,
      endpoint: endpoint,
      socket_module: socket_module,
      headers: headers
    }
  end

  for transport <- [:mtls, :ssh] do
    @tag transport: transport
    test "actual #{transport} V2 websocket joins heartbeats and commits a complete note",
         context do
      {tcp, response} =
        open(context.port, context.headers)

      assert response =~ "101 Switching Protocols"

      hello = %{
        "protocol_version" => 1,
        "node_id" => context.peer.id,
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      }

      send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", hello])

      assert [
               "join",
               "join",
               "note_sync:v1",
               "phx_reply",
               %{"status" => "ok", "response" => joined}
             ] = receive_frame(tcp)

      assert joined["node_id"] != context.peer.id
      guard = session_guard(context)

      on_exit(fn ->
        monitor = Process.monitor(guard)
        :gen_tcp.close(tcp)
        assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000
      end)

      send_frame(tcp, [nil, "heartbeat", "phoenix", "heartbeat", %{}])
      assert [nil, "heartbeat", "phoenix", "phx_reply", %{"status" => "ok"}] = receive_frame(tcp)
      clock = %{"millis" => 1_791_676_800_000, "counter" => 0, "node_id" => context.peer.id}

      snapshot = %{
        "title" => "wire",
        "content" => "actual websocket",
        "labels" => [
          %{
            "key" => "project",
            "value" => "bear_note",
            "description" => "",
            "value_type" => "text"
          }
        ],
        "created_at" => 1_791_676_800,
        "updated_at" => 1_791_676_800,
        "deleted_at" => nil,
        "attachments" => []
      }

      event = %{
        "event_id" => Ecto.UUID.generate(),
        "note_id" => Ecto.UUID.generate(),
        "generation" => clock,
        "control" => clock,
        "version" => clock,
        "kind" => "attach",
        "snapshot" => snapshot,
        "snapshot_hash" => Protocol.snapshot_hash(snapshot)
      }

      bytes = Jason.encode!(event)
      transfer = Ecto.UUID.generate()

      request(tcp, "begin", "transfer_begin", %{
        "transfer_id" => transfer,
        "size_bytes" => byte_size(bytes),
        "checksum_sha256" => Protocol.sha256(bytes)
      })

      send_frame(tcp, [
        "join",
        nil,
        "note_sync:v1",
        "blob_chunk",
        %{
          "transfer_id" => transfer,
          "blob_id" => "event",
          "offset" => 0,
          "data" => Base.encode64(bytes)
        }
      ])

      request(tcp, "end", "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})

      send_frame(tcp, [
        "join",
        "commit",
        "note_sync:v1",
        "transfer_commit",
        %{"transfer_id" => transfer}
      ])

      ack = Protocol.ack(event)
      assert ["join", nil, "note_sync:v1", "ack", ^ack] = receive_frame(tcp)

      assert [
               "join",
               "commit",
               "note_sync:v1",
               "phx_reply",
               %{"status" => "ok", "response" => ^ack}
             ] = receive_frame(tcp)

      assert %Note{title: "wire"} = GSMLG.Repo.get(Note, event["note_id"])
      :gen_tcp.close(tcp)
    end

    @tag transport: transport
    test "actual #{transport} V2 websocket sends historical inventory and clears pending after a complete ACK",
         context do
      old = %{DateTime.from_unix!(1_600_000_000) | microsecond: {0, 6}}

      note =
        GSMLG.Repo.insert!(%Note{
          title: "historical wire",
          content: "inventory over an actual websocket",
          created_at: old,
          updated_at: old
        })

      {:ok, setting} = Compat.define_label_key("project", "")

      GSMLG.Repo.insert!(%Label{
        note_id: note.id,
        label_setting_id: setting.id,
        value: "bear_note"
      })

      assert Sync.pending(context.peer.id) == []
      assert Sync.membership(context.peer.id, note.id) == nil

      {tcp, response} =
        open(context.port, context.headers)

      assert response =~ "101 Switching Protocols"

      hello = %{
        "protocol_version" => 1,
        "node_id" => context.peer.id,
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      }

      send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", hello])

      assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "ok"}] =
               receive_frame(tcp)

      guard = session_guard(context)

      on_exit(fn ->
        monitor = Process.monitor(guard)
        :gen_tcp.close(tcp)
        assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000
      end)

      request(tcp, "inventory", "inventory_start", %{})

      assert ["join", begin_ref, "note_sync:v1", "transfer_begin", manifest] = receive_frame(tcp)
      transfer = manifest["transfer_id"]
      assert Protocol.uuid?(transfer)
      assert is_binary(begin_ref)
      reply(tcp, begin_ref, %{})
      {bytes, end_ref} = receive_event_blob(tcp, transfer, "")
      assert byte_size(bytes) == manifest["size_bytes"]
      assert Protocol.sha256(bytes) == manifest["checksum_sha256"]

      snapshot = %{
        "title" => note.title,
        "content" => note.content,
        "labels" => [
          %{
            "key" => "project",
            "value" => "bear_note",
            "description" => "",
            "value_type" => "text"
          }
        ],
        "created_at" => 1_600_000_000,
        "updated_at" => 1_600_000_000,
        "deleted_at" => nil,
        "attachments" => []
      }

      event = Jason.decode!(bytes)
      assert :ok = Protocol.validate_event(event)
      assert event["note_id"] == note.id
      assert event["snapshot"] == snapshot
      assert event["snapshot_hash"] == Protocol.snapshot_hash(snapshot)
      assert event["version"]["millis"] == 1_600_000_000_000
      assert [pending] = Sync.pending(context.peer.id)
      assert pending == event
      reply(tcp, end_ref, %{})

      assert [
               "join",
               commit_ref,
               "note_sync:v1",
               "transfer_commit",
               %{"transfer_id" => ^transfer}
             ] =
               receive_frame(tcp)

      ack = Protocol.ack(event)
      send_frame(tcp, ["join", nil, "note_sync:v1", "ack", ack])
      reply(tcp, commit_ref, ack)

      assert ["join", nil, "note_sync:v1", "inventory_complete", %{}] = receive_frame(tcp)
      assert Sync.pending(context.peer.id) == []
      :gen_tcp.close(tcp)
    end
  end

  test "actual ingress rejects missing duplicate and unregistered certificate identities",
       context do
    for headers <- [
          [],
          [{"X-Note-Sync-Client-Fingerprint", String.duplicate("0", 64)}],
          [
            {"X-Note-Sync-Client-Fingerprint", context.fingerprint},
            {"X-Note-Sync-Client-Fingerprint", context.fingerprint}
          ]
        ] do
      {tcp, response} = open(context.port, headers)
      assert response =~ "403 Forbidden"
      :gen_tcp.close(tcp)
    end
  end

  @tag transport: :ssh
  test "SSH joins require an explicitly registered peer and its exact authorized profile",
       context do
    {:ok, mtls_peer} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        actor_id: "mtls-only",
        certificate_fingerprint: context.fingerprint,
        allowed_selectors: ["project=bear_note"]
      })

    payload = hello(context.peer)

    for invalid <- [
          Map.put(payload, "node_id", Ecto.UUID.generate()),
          Map.put(payload, "node_id", mtls_peer.id),
          Map.put(payload, "node_id", String.upcase(context.peer.id)),
          Map.put(payload, "selectors", ["project=other"]),
          Map.put(payload, "actor_id", "spoof")
        ] do
      {tcp, response} = open(context.port, [])
      assert response =~ "101 Switching Protocols"
      send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", invalid])

      assert [
               "join",
               "join",
               "note_sync:v1",
               "phx_reply",
               %{"status" => "error", "response" => %{"code" => "unauthorized"}}
             ] =
               receive_frame(tcp)

      :gen_tcp.close(tcp)
    end
  end

  @tag transport: :ssh
  test "revocation and selector changes close established SSH websockets", context do
    for change <- [:revoke, :select] do
      {:ok, peer} =
        Sync.register_ssh_peer(%{
          node_id: Ecto.UUID.generate(),
          actor_id: "disconnect-peer",
          allowed_selectors: ["project=bear_note", "project=other"]
        })

      {tcp, response} = open(context.port, [])
      assert response =~ "101 Switching Protocols"
      send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", hello(peer)])

      assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "ok"}] =
               receive_frame(tcp)

      guard = session_guard(%{context | peer: peer})
      monitor = Process.monitor(guard)

      case change do
        :revoke -> assert :ok = Sync.revoke_peer(peer.id)
        :select -> assert {:ok, _} = Sync.select(peer.id, ["project=other"])
      end

      assert_closed(tcp)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000

      if change == :revoke do
        {retry, _response} = open(context.port, [])
        send_frame(retry, ["join", "join", "note_sync:v1", "phx_join", hello(peer)])

        assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "error"}] =
                 receive_frame(retry)

        :gen_tcp.close(retry)
      end

      :gen_tcp.close(tcp)
    end
  end

  @tag transport: :ssh
  test "SSH listener serves no admin HTTP pages or alternate sockets", context do
    for path <- [
          "/",
          "/users/log_in",
          "/socket/websocket?vsn=2.0.0",
          "/note-sync/longpoll?vsn=2.0.0"
        ] do
      {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, context.port, [:binary, active: false], 2000)

      :ok =
        :gen_tcp.send(tcp, "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      assert receive_headers(tcp, "") =~ "404 Not Found"
      :gen_tcp.close(tcp)
    end
  end

  test "SSH peer UUID in the public socket query cannot replace certificate identity", context do
    {:ok, peer} =
      Sync.register_ssh_peer(%{
        node_id: Ecto.UUID.generate(),
        actor_id: "ssh-only",
        allowed_selectors: ["project=bear_note"]
      })

    {tcp, response} = open(context.port, [], "&node_id=#{peer.id}")
    assert response =~ "403 Forbidden"
    :gen_tcp.close(tcp)
  end

  defp hello(peer) do
    %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }
  end

  defp assert_closed(tcp, remaining_frames \\ 2) do
    assert remaining_frames > 0

    case :gen_tcp.recv(tcp, 2, 2000) do
      {:ok, <<0x88, size>>} ->
        assert {:ok, <<1001::16, _::binary>>} = :gen_tcp.recv(tcp, size, 2000)

      {:ok, <<0x81, size>>} when size < 126 ->
        assert {:ok, _payload} = :gen_tcp.recv(tcp, size, 2000)
        assert_closed(tcp, remaining_frames - 1)
    end
  end

  defp session_guard(context) do
    peer_id = context.peer.id
    table = context.endpoint.config({:socket, context.socket_module})

    guards =
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {key, _pid} -> is_integer(key) end)
      |> Enum.flat_map(fn {_index, supervisor} ->
        DynamicSupervisor.which_children(supervisor)
      end)
      |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
        case :sys.get_state(pid) do
          %Phoenix.Socket{assigns: %{session_peer: %{id: ^peer_id}, guard: guard}} -> [guard]
          _ -> []
        end
      end)

    assert [guard] = guards
    guard
  end

  defp open(port, headers, query \\ "") do
    {:ok, tcp} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2000)

    on_exit(fn -> :gen_tcp.close(tcp) end)
    fields = Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(tcp, [
        "GET /note-sync/websocket?vsn=2.0.0#{query} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
        fields,
        "\r\n"
      ])

    {tcp, receive_headers(tcp, "")}
  end

  defp receive_headers(tcp, collected) do
    if String.contains?(collected, "\r\n\r\n") do
      collected
    else
      {:ok, bytes} = :gen_tcp.recv(tcp, 0, 2000)
      receive_headers(tcp, collected <> bytes)
    end
  end

  defp request(tcp, ref, event, payload) do
    send_frame(tcp, ["join", ref, "note_sync:v1", event, payload])

    assert ["join", ^ref, "note_sync:v1", "phx_reply", %{"status" => "ok", "response" => %{}}] =
             receive_frame(tcp)
  end

  defp reply(tcp, ref, payload),
    do:
      send_frame(tcp, [
        "join",
        ref,
        "note_sync:v1",
        "phx_reply",
        %{status: "ok", response: payload}
      ])

  defp receive_event_blob(tcp, transfer, bytes) do
    case receive_frame(tcp) do
      ["join", nil, "note_sync:v1", "blob_chunk", payload] ->
        assert payload["transfer_id"] == transfer
        assert payload["blob_id"] == "event"
        assert payload["offset"] == byte_size(bytes)
        chunk = Base.decode64!(payload["data"])
        assert byte_size(chunk) in 1..65_536
        assert Base.encode64(chunk) == payload["data"]
        receive_event_blob(tcp, transfer, bytes <> chunk)

      ["join", ref, "note_sync:v1", "blob_end", payload] ->
        assert payload == %{"transfer_id" => transfer, "blob_id" => "event"}
        assert is_binary(ref)
        {bytes, ref}
    end
  end

  defp send_frame(tcp, frame) do
    bytes = Jason.encode!(frame)
    mask = <<1, 2, 3, 4>>

    masked =
      for <<byte <- bytes>>, reduce: {[], 0} do
        {result, index} -> {[bxor(byte, :binary.at(mask, rem(index, 4))) | result], index + 1}
      end
      |> elem(0)
      |> Enum.reverse()
      |> :binary.list_to_bin()

    header =
      if byte_size(bytes) < 126,
        do: <<0x81, 0x80 + byte_size(bytes)>>,
        else: <<0x81, 0xFE, byte_size(bytes)::16>>

    :ok = :gen_tcp.send(tcp, [header, mask, masked])
  end

  defp receive_frame(tcp) do
    {:ok, <<0x81, length>>} = :gen_tcp.recv(tcp, 2, 2000)

    size =
      case length do
        126 ->
          {:ok, <<size::16>>} = :gen_tcp.recv(tcp, 2, 2000)
          size

        127 ->
          {:ok, <<size::64>>} = :gen_tcp.recv(tcp, 8, 2000)
          size

        size ->
          size
      end

    {:ok, payload} = :gen_tcp.recv(tcp, size, 2000)
    Jason.decode!(payload)
  end
end
