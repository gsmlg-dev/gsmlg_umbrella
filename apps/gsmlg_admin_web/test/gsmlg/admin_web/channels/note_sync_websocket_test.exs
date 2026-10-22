defmodule GSMLG.AdminWeb.NoteSyncWebSocketTest do
  use GSMLG.AdminWeb.ChannelCase, async: false
  import Bitwise
  alias GSMLG.GaoNote.{Compat, Label, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}
  alias GSMLG.Storage.TestCatalogClient

  defmodule StalledAttachmentStub do
    import Plug.Conn

    def init(options), do: options

    def call(conn, options) do
      send(options[:owner], {:attachment_read_started, self()})

      receive do
        :continue_read -> send_resp(conn, 206, options[:bytes])
      after
        30_000 -> raise "attachment preparation barrier timed out"
      end
    end
  end

  setup do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)

    Application.put_env(:gsmlg_gao_note, :note_sync, %{
      max_blob_bytes: 536_870_912
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    peer = %{id: Ecto.UUID.generate()}
    endpoint = GSMLG.AdminWeb.Endpoint

    [listener] =
      Gaoxy.PhoenixAdapter.child_specs(endpoint,
        server: true,
        http: [ip: {127, 0, 0, 1}, port: 0]
      )

    start_supervised!(listener)
    assert {:ok, {{127, 0, 0, 1}, port}} = Gaoxy.PhoenixAdapter.server_info(endpoint, :http)

    %{
      peer: peer,
      port: port,
      endpoint: endpoint,
      socket_module: GSMLG.AdminWeb.NoteSyncSocket,
      headers: []
    }
  end

  test "anonymous V2 websocket joins heartbeats and commits a complete note",
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

  test "anonymous V2 websocket sends historical inventory and clears pending after a complete ACK",
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

  test "pre-announcement read timeout preserves the websocket, inbound transfer and other pending notes",
       context do
    TestCatalogClient.setup!()
    stalled_attachment_server("slow attachment")

    {tcp, response} = open(context.port, [])
    assert response =~ "101 Switching Protocols"
    send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", hello(context.peer)])

    assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "ok"}] =
             receive_frame(tcp)

    {channel, joined} = session_channel(context)
    guard = joined.assigns.guard
    channel_monitor = Process.monitor(channel)
    guard_monitor = Process.monitor(guard)

    on_exit(fn ->
      monitor = Process.monitor(guard)
      :gen_tcp.close(tcp)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000
    end)

    {:ok, stalled} =
      Compat.save_note(
        %{title: "stalled attachment", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    file =
      TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
        tenant: "gao_note",
        type: "attachment",
        filename: "slow.txt",
        s3_key: Ecto.UUID.generate(),
        content_type: "text/plain",
        size: byte_size("slow attachment"),
        checksum: Protocol.sha256("slow attachment")
      })

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: Ecto.UUID.generate(),
      note_id: stalled.id,
      storage_file_id: file.id,
      path: "./slow.txt",
      mime: "text/plain"
    })

    {:ok, _} = Compat.patch_note(stalled.id, stalled.revision, %{content: "with attachment"}, nil)
    request(tcp, "inventory", "inventory_start", %{})
    assert_receive {:attachment_read_started, reader}, 2000
    on_exit(fn -> send(reader, :continue_read) end)
    preparing = :sys.get_state(channel)
    task = preparing.assigns.read_task
    outgoing = preparing.assigns.outgoing
    assert outgoing.event["note_id"] == stalled.id
    assert outgoing.phase == :preparing
    assert Store.get("lease", outgoing.lease, context.peer.id)
    task_monitor = Process.monitor(task.pid)

    # A duplex inbound transfer is already staged when the outbound preparation fails.
    incoming = incoming_event(context.peer)
    incoming_transfer = stage_incoming(tcp, incoming)
    incoming_directory = :sys.get_state(channel).assigns.incoming.directory
    assert File.dir?(incoming_directory)
    assert_wire_heartbeat(tcp, "while-preparing")
    assert :sys.get_state(channel).assigns.waiting == nil

    send(channel, {:task_deadline, task.ref})
    assert_receive {:DOWN, ^task_monitor, :process, _, _}, 2000

    await_channel(channel, fn state ->
      is_nil(state.assigns.outgoing) and
        Store.get("lease", outgoing.lease, context.peer.id) == nil
    end)

    refute File.exists?(outgoing.directory)
    assert File.dir?(incoming_directory)
    assert Enum.any?(Sync.pending(context.peer.id), &(&1["note_id"] == stalled.id))
    assert_wire_heartbeat(tcp, "after-timeout")
    assert Process.alive?(channel)
    assert Process.alive?(guard)
    refute_received {:DOWN, ^channel_monitor, :process, ^channel, _}
    refute_received {:DOWN, ^guard_monitor, :process, ^guard, _}

    # Results and timers belonging to the abandoned worker cannot affect its successor.
    send(channel, {task.ref, {:error, :stale_read_result}})
    send(channel, {:task_deadline, task.ref})
    {preparation_token, _} = preparing.assigns.preparation_timer
    send(channel, {:preparation_deadline, preparation_token})
    send(channel, :poll_pending)
    assert_wire_heartbeat(tcp, "after-stale-messages")
    refute_receive {:attachment_read_started, _}, 100
    assert :sys.get_state(channel).assigns.read_task == nil

    send_frame(tcp, [
      "join",
      "incoming-commit",
      "note_sync:v1",
      "transfer_commit",
      %{"transfer_id" => incoming_transfer}
    ])

    incoming_ack = Protocol.ack(incoming)
    assert ["join", nil, "note_sync:v1", "ack", ^incoming_ack] = receive_sync_frame(tcp)

    assert [
             "join",
             "incoming-commit",
             "note_sync:v1",
             "phx_reply",
             %{"status" => "ok", "response" => ^incoming_ack}
           ] = receive_sync_frame(tcp)

    assert GSMLG.Repo.get!(Note, incoming["note_id"]).title == "independent inbound"

    {:ok, healthy} =
      Compat.save_note(
        %{
          title: "healthy after timeout",
          content: "continues",
          labels: [["project", "bear_note"]]
        },
        nil
      )

    send(channel, :poll_pending)

    assert ["join", begin_ref, "note_sync:v1", "transfer_begin", manifest] =
             receive_sync_frame(tcp)

    assert {^channel, _} = session_channel(context)
    transfer = manifest["transfer_id"]
    reply(tcp, begin_ref, %{})
    {bytes, end_ref} = receive_event_blob(tcp, transfer, "")
    event = Jason.decode!(bytes)
    assert event["note_id"] == healthy.id
    reply(tcp, end_ref, %{})

    assert [
             "join",
             commit_ref,
             "note_sync:v1",
             "transfer_commit",
             %{"transfer_id" => ^transfer}
           ] = receive_frame(tcp)

    ack = Protocol.ack(event)
    send_frame(tcp, ["join", nil, "note_sync:v1", "ack", ack])
    reply(tcp, commit_ref, ack)

    await_channel(channel, fn state ->
      is_nil(state.assigns.outgoing) and
        Enum.map(Sync.pending(context.peer.id), & &1["note_id"]) == [stalled.id]
    end)

    send(channel, :poll_pending)
    assert_wire_heartbeat(tcp, "after-healthy-ack")
    refute_receive {:attachment_read_started, _}, 100
    assert Store.get("lease", outgoing.lease, context.peer.id) == nil
    assert :sys.get_state(channel).assigns.read_task == nil
    assert {^channel, _} = session_channel(context)
  end

  test "ingress accepts connections without certificate or browser credentials", context do
    for headers <- [
          [],
          [{"X-Note-Sync-Client-Fingerprint", "ignored"}],
          [
            {"X-Note-Sync-Client-Fingerprint", "ignored"},
            {"X-Note-Sync-Client-Fingerprint", "also ignored"}
          ]
        ] do
      {tcp, response} = open(context.port, headers)
      assert response =~ "101 Switching Protocols"
      :gen_tcp.close(tcp)
    end
  end

  test "anonymous joins still reject malformed protocol payloads", context do
    payload = hello(context.peer)

    for invalid <- [
          %{},
          Map.put(payload, "node_id", "invalid"),
          Map.put(payload, "node_id", String.upcase(context.peer.id)),
          Map.put(payload, "selectors", []),
          Map.put(payload, "max_blob_bytes", 0),
          Map.put(payload, "protocol_version", 2),
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
               %{"status" => "error", "response" => %{"code" => "invalid_join"}}
             ] = receive_frame(tcp)

      :gen_tcp.close(tcp)
    end

    refute GSMLG.Repo.get(GSMLG.GaoNote.Sync.Peer, context.peer.id)
  end

  test "administrative changes close current sessions without blocking anonymous reconnect",
       context do
    for change <- [:revoke, :select] do
      peer = %{id: Ecto.UUID.generate()}
      payload = Map.put(hello(peer), "selectors", ["project=bear_note", "project=other"])
      {tcp, response} = open(context.port, [])
      assert response =~ "101 Switching Protocols"
      send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", payload])

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
      :gen_tcp.close(tcp)

      {retry, response} = open(context.port, [])
      assert response =~ "101 Switching Protocols"
      send_frame(retry, ["join", "join", "note_sync:v1", "phx_join", hello(peer)])

      assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "ok"}] =
               receive_frame(retry)

      retry_guard = session_guard(%{context | peer: peer})
      retry_monitor = Process.monitor(retry_guard)
      :gen_tcp.close(retry)
      assert_receive {:DOWN, ^retry_monitor, :process, ^retry_guard, _}, 5000
    end
  end

  test "shared listener keeps admin pages authenticated and longpoll disabled", context do
    for {path, status} <- [
          {"/gao_notes/notes", "302 Found"},
          {"/note-sync/longpoll?vsn=2.0.0", "404 Not Found"}
        ] do
      {:ok, tcp} = :gen_tcp.connect({127, 0, 0, 1}, context.port, [:binary, active: false], 2000)

      :ok =
        :gen_tcp.send(tcp, "GET #{path} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

      assert receive_headers(tcp, "") =~ status
      :gen_tcp.close(tcp)
    end
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
        assert {:ok, <<code::16, _::binary>>} = :gen_tcp.recv(tcp, size, 2000)
        assert code in [1000, 1001]

      {:ok, <<0x81, size>>} when size < 126 ->
        assert {:ok, _payload} = :gen_tcp.recv(tcp, size, 2000)
        assert_closed(tcp, remaining_frames - 1)
    end
  end

  defp session_guard(context) do
    {_channel, socket} = session_channel(context)
    socket.assigns.guard
  end

  defp session_channel(context) do
    peer_id = context.peer.id
    table = context.endpoint.config({:socket, context.socket_module})

    channels =
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {key, _pid} -> is_integer(key) end)
      |> Enum.flat_map(fn {_index, supervisor} ->
        DynamicSupervisor.which_children(supervisor)
      end)
      |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
        case :sys.get_state(pid) do
          %Phoenix.Socket{assigns: %{session_peer: %{id: ^peer_id}}} = socket -> [{pid, socket}]
          _ -> []
        end
      end)

    assert [channel] = channels
    channel
  end

  defp await_channel(channel, predicate, attempts \\ 200)

  defp await_channel(channel, predicate, attempts) when attempts > 0 do
    state = :sys.get_state(channel)

    if predicate.(state) do
      state
    else
      Process.sleep(10)
      await_channel(channel, predicate, attempts - 1)
    end
  end

  defp await_channel(channel, predicate, 0) do
    state = :sys.get_state(channel)
    assert predicate.(state)
    state
  end

  defp stalled_attachment_server(bytes) do
    listener =
      start_supervised!(
        {Bandit,
         plug: {StalledAttachmentStub, owner: self(), bytes: bytes},
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false},
        id: :stalled_attachment
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(listener)

    previous =
      Map.new([:s3_bucket, :s3_endpoint], &{&1, Application.fetch_env(:gsmlg_storage, &1)})

    Application.put_env(:gsmlg_storage, :s3_bucket, "websocket-preparation-test")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)
  end

  defp incoming_event(peer) do
    clock = %{"millis" => 1_791_676_800_000, "counter" => 0, "node_id" => peer.id}

    snapshot = %{
      "title" => "independent inbound",
      "content" => "survives outgoing preparation timeout",
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

    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => Ecto.UUID.generate(),
      "generation" => clock,
      "control" => clock,
      "version" => clock,
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    }
  end

  defp stage_incoming(tcp, event) do
    bytes = Jason.encode!(event)
    transfer = Ecto.UUID.generate()

    request(tcp, "incoming-begin", "transfer_begin", %{
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

    request(tcp, "incoming-end", "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
    transfer
  end

  defp assert_wire_heartbeat(tcp, ref) do
    send_frame(tcp, [nil, ref, "phoenix", "heartbeat", %{}])
    assert [nil, ^ref, "phoenix", "phx_reply", %{"status" => "ok"}] = receive_sync_frame(tcp)
  end

  defp receive_sync_frame(tcp) do
    case receive_frame(tcp) do
      ["join", nil, "note_sync:v1", "inventory_complete", %{}] -> receive_sync_frame(tcp)
      frame -> frame
    end
  end

  defp open(port, headers) do
    {:ok, tcp} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2000)

    on_exit(fn -> :gen_tcp.close(tcp) end)
    fields = Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(tcp, [
        "GET /note-sync/websocket?vsn=2.0.0 HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
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
