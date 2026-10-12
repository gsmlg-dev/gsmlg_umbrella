defmodule GSMLG.AdminWeb.NoteSyncChannelTest do
  use GSMLG.AdminWeb.ChannelCase, async: false
  alias GSMLG.AdminWeb.{NoteSyncSocket, NoteSyncChannel}
  alias GSMLG.GaoNote.{Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.Protocol

  setup do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)

    Application.put_env(:gsmlg_gao_note, :note_sync, %{
      enabled: true,
      trusted_proxy_ips: ["127.0.0.1"],
      max_blob_bytes: 536_870_912
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    fingerprint = Protocol.sha256(Ecto.UUID.generate())

    {:ok, peer} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: fingerprint,
        actor_id: "channel-peer",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, authenticated} =
      connect(NoteSyncSocket, %{"actor_id" => "spoof"},
        connect_info: %{
          peer_data: %{address: {127, 0, 0, 1}},
          x_headers: [{"x-note-sync-client-fingerprint", fingerprint}]
        }
      )

    payload = %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }

    {:ok, response, socket} =
      subscribe_and_join(authenticated, NoteSyncChannel, "note_sync:v1", payload)

    Process.unlink(socket.channel_pid)
    guard = socket.assigns.guard

    on_exit(fn ->
      monitor = Process.monitor(guard)
      if Process.alive?(socket.channel_pid), do: Process.exit(socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000
    end)

    %{
      peer: peer,
      authenticated: authenticated,
      socket: socket,
      response: response,
      payload: payload
    }
  end

  test "verified certificate binds actor and authorized exact requested selector profile",
       context do
    assert context.socket.assigns.session_peer.actor_id == "channel-peer"
    assert context.response["node_id"] != context.peer.id
    assert context.response["selectors"] == ["project=bear_note"]

    assert {:error, %{code: "unauthorized"}} =
             subscribe_and_join(
               context.authenticated,
               NoteSyncChannel,
               "note_sync:v1",
               Map.put(context.payload, "selectors", ["project=other"])
             )

    assert {:error, %{code: "unauthorized"}} =
             subscribe_and_join(
               context.authenticated,
               NoteSyncChannel,
               "note_sync:v1",
               Map.put(context.payload, "node_id", Ecto.UUID.generate())
             )
  end

  test "committed inbound transfer preserves UUID and returns full ACK", %{
    socket: socket,
    peer: peer
  } do
    event = event(peer)
    transfer = stage(socket, event)
    ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
    expected = Protocol.ack(event)
    assert_reply(ref, :ok, ^expected)
    assert_push("ack", ^expected)
    assert %Note{id: id, title: "remote"} = GSMLG.Repo.get(Note, event["note_id"])
    assert id == event["note_id"]
    assert socket.assigns.session_peer.actor_id == "channel-peer"
  end

  test "no-ref commit pushes committed ACK and catalog rejection without poisoning next note", %{
    socket: socket,
    peer: peer
  } do
    {:ok, _} = Compat.define_label_key("project", %{description: "local"})
    bad = event(peer)
    transfer = stage(socket, bad)

    send(socket.channel_pid, %Phoenix.Socket.Message{
      join_ref: socket.join_ref,
      ref: nil,
      topic: socket.topic,
      event: "transfer_commit",
      payload: %{"transfer_id" => transfer}
    })

    assert_push("note_rejected", %{
      "code" => "note_rejected",
      "event_id" => event_id,
      "note_id" => note_id,
      "reason" => "catalog_conflict"
    })

    assert event_id == bad["event_id"] and note_id == bad["note_id"]
    refute GSMLG.Repo.get(Note, note_id)
    good = put_in(event(peer), ["snapshot", "labels", Access.at(0), "description"], "local")
    good = Map.put(good, "snapshot_hash", Protocol.snapshot_hash(good["snapshot"]))
    transfer = stage(socket, good)

    send(socket.channel_pid, %Phoenix.Socket.Message{
      join_ref: socket.join_ref,
      ref: nil,
      topic: socket.topic,
      event: "transfer_commit",
      payload: %{"transfer_id" => transfer}
    })

    expected = Protocol.ack(good)
    assert_push("ack", ^expected)
    assert GSMLG.Repo.get(Note, good["note_id"])
  end

  test "outbound inventory continues servicing inbound transfers while waiting for peer reply", %{
    socket: socket,
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(
        %{
          title: "large local",
          content: String.duplicate("a", 150_000),
          labels: [["project", "bear_note"]]
        },
        nil
      )

    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{})

    assert_receive %Phoenix.Socket.Message{
                     event: "transfer_begin",
                     ref: begin_ref,
                     payload: begin_payload
                   },
                   2000

    assert is_binary(begin_ref)
    incoming = event(peer)
    transfer = stage(socket, incoming)
    commit_ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
    ack = Protocol.ack(incoming)
    assert_reply(commit_ref, :ok, ^ack)
    assert_push("ack", ^ack)
    reply(socket, begin_ref, %{})
    metadata = collect_blob(socket, begin_payload["transfer_id"], "event", [])
    outgoing = Jason.decode!(metadata)
    assert outgoing["note_id"] == note.id
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: commit_ref}, 2000
    reply(socket, commit_ref, Protocol.ack(outgoing))
    assert_push("inventory_complete", %{}, 2000)
    assert Sync.pending(peer.id) == []
  end

  test "blocked inventory coalesces requests and still services inbound frames and task deadlines",
       %{socket: socket, peer: peer} do
    blocker = hold_database()

    try do
      ref = push(socket, "inventory_start", %{})
      task = channel_state(socket).assigns.inventory_task
      assert is_pid(task.pid)
      duplicate = push(socket, "inventory_start", %{})
      assert_reply(duplicate, :ok, %{})
      assert channel_state(socket).assigns.inventory_task.ref == task.ref
      refute_reply(ref, :ok, %{}, 10)
      stage(socket, event(peer))
      assert channel_state(socket).assigns.incoming.event["kind"] == "attach"
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:task_deadline, task.ref})
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
    after
      release_database(blocker)
    end
  end

  test "blocked pending poll coalesces ticks and leaves inbound deadline responsive", %{
    socket: socket,
    peer: peer
  } do
    blocker = hold_database()

    try do
      send(socket.channel_pid, :poll_pending)
      task = channel_state(socket).assigns.pending_task
      assert is_pid(task.pid)
      send(socket.channel_pid, :poll_pending)
      assert channel_state(socket).assigns.pending_task.ref == task.ref
      stage(socket, event(peer))
      {token, _} = channel_state(socket).assigns.incoming_timer
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:incoming_deadline, token})
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
    after
      release_database(blocker)
    end
  end

  test "blocked event finalization runs off channel and retains its reply until completion", %{
    socket: socket,
    peer: peer
  } do
    bytes = Jason.encode!(event(peer))
    transfer = Ecto.UUID.generate()

    ref =
      push(socket, "transfer_begin", %{
        "transfer_id" => transfer,
        "size_bytes" => byte_size(bytes),
        "checksum_sha256" => Protocol.sha256(bytes)
      })

    assert_reply(ref, :ok, %{})

    push(socket, "blob_chunk", %{
      "transfer_id" => transfer,
      "blob_id" => "event",
      "offset" => 0,
      "data" => Base.encode64(bytes)
    })

    path = channel_state(socket).assigns.incoming.blobs["event"].path
    File.rm!(path)
    assert {"", 0} = System.cmd("mkfifo", [path])

    writer =
      Port.open({:spawn_executable, System.find_executable("python3")}, [
        :binary,
        :exit_status,
        args: ["-c", "import os, sys, time
sys.stdin.buffer.read(1)
end = time.monotonic() + 0.5
while time.monotonic() < end:
 try:
  fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
  os.write(fd, sys.argv[2].encode())
  os.close(fd)
  break
 except OSError:
  time.sleep(0.005)", path, bytes]
      ])

    try do
      ref = push(socket, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
      task = channel_state(socket).assigns.blob_task
      assert is_pid(task.pid)
      refute_reply(ref, :ok, %{}, 10)
      heartbeat = push(socket, "inventory_complete", %{})
      assert_reply(heartbeat, :ok, %{})
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:task_deadline, task.ref})
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
    after
      # File.read uses the VM file server. Start the external writer before the
      # read blocks, then signal through its port without calling that server.
      Port.command(writer, "release")
      assert_receive {^writer, {:exit_status, 0}}, 1000
    end
  end

  test "exact early ACK and rejection cannot release a lease while its attachment read is blocked",
       %{socket: socket} do
    {:ok, note} =
      Compat.save_note(
        %{title: "attachment", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    file =
      GSMLG.Repo.insert!(%GSMLG.Storage.StorageFile{
        tenant: "gao_note",
        type: "attachment",
        filename: "x.txt",
        s3_key: Ecto.UUID.generate(),
        content_type: "text/plain",
        size: 1,
        checksum: Protocol.sha256("x")
      })

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: Ecto.UUID.generate(),
      note_id: note.id,
      storage_file_id: file.id,
      path: "./x.txt",
      mime: "text/plain"
    })

    {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "attachment body"}, nil)
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{})

    assert_receive %Phoenix.Socket.Message{
                     event: "transfer_begin",
                     ref: begin_ref,
                     payload: begin_payload
                   },
                   2000

    blocker = hold_database()

    try do
      reply(socket, begin_ref, %{})

      outgoing =
        socket |> collect_blob(begin_payload["transfer_id"], "event", []) |> Jason.decode!()

      state = await_state(socket, &(&1.assigns.outgoing.phase == :reading))
      lease = state.assigns.outgoing.lease
      push(socket, "ack", Protocol.ack(outgoing))
      assert channel_state(socket).assigns.outgoing.lease == lease

      push(socket, "note_rejected", %{
        "code" => "note_rejected",
        "event_id" => outgoing["event_id"],
        "note_id" => note.id,
        "reason" => "validation_failed"
      })

      state = channel_state(socket)
      assert state.assigns.outgoing.lease == lease
      assert is_nil(state.assigns.confirmation_task)
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:task_deadline, state.assigns.read_task.ref})
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
    after
      release_database(blocker)
    end
  end

  test "pushed committed ACK is accepted before the commit request reply", %{socket: socket} do
    {:ok, _} =
      Compat.save_note(
        %{title: "local", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{})

    assert_receive %Phoenix.Socket.Message{
                     event: "transfer_begin",
                     ref: begin_ref,
                     payload: payload
                   },
                   2000

    reply(socket, begin_ref, %{})
    outgoing = socket |> collect_blob(payload["transfer_id"], "event", []) |> Jason.decode!()
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: commit_ref}, 2000
    push(socket, "ack", Protocol.ack(outgoing))
    assert_push("inventory_complete", %{}, 2000)
    reply(socket, commit_ref, Protocol.ack(outgoing))
    ref = push(socket, "inventory_complete", %{})
    assert_reply(ref, :ok, %{})
  end

  test "blocked committed ACK coalesces duplicate confirmations and services inbound frames", %{
    socket: socket,
    peer: peer
  } do
    {:ok, _} =
      Compat.save_note(
        %{title: "local", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{})

    assert_receive %Phoenix.Socket.Message{
                     event: "transfer_begin",
                     ref: begin_ref,
                     payload: payload
                   },
                   2000

    reply(socket, begin_ref, %{})
    outgoing = socket |> collect_blob(payload["transfer_id"], "event", []) |> Jason.decode!()
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit"}, 2000
    blocker = hold_database()

    try do
      push(socket, "ack", Protocol.ack(outgoing))
      task = channel_state(socket).assigns.confirmation_task
      assert is_pid(task.pid)
      push(socket, "ack", Protocol.ack(outgoing))
      assert channel_state(socket).assigns.confirmation_task.ref == task.ref
      stage(socket, event(peer))
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:task_deadline, task.ref})
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
    after
      release_database(blocker)
    end
  end

  # Holding a real transaction reserves the shared Sandbox connection. Sync
  # queries wait for that connection, reproducing blocked DB work without mocks.
  defp hold_database do
    owner = self()

    task =
      Task.async(fn ->
        GSMLG.Repo.transaction(fn ->
          Ecto.Adapters.SQL.query!(GSMLG.Repo, "SELECT 1")
          send(owner, {:database_held, self()})

          receive do
            :release_database -> :ok
          after
            5000 -> raise "database barrier timed out"
          end
        end)
      end)

    assert_receive {:database_held, pid}, 1000
    assert pid == task.pid
    task
  end

  defp release_database(task) do
    send(task.pid, :release_database)
    assert {:ok, :ok} = Task.await(task, 2000)
  end

  defp channel_state(socket), do: :sys.get_state(socket.channel_pid, 1000)

  defp await_state(socket, predicate, attempts \\ 100) do
    state = channel_state(socket)

    cond do
      predicate.(state) ->
        state

      attempts > 0 ->
        Process.sleep(5)
        await_state(socket, predicate, attempts - 1)

      true ->
        flunk("channel did not reach expected state")
    end
  end

  defp event(peer) do
    clock = %{"millis" => 1_791_676_800_000, "counter" => 0, "node_id" => peer.id}

    snapshot = %{
      "title" => "remote",
      "content" => "body",
      "labels" => [
        %{"key" => "project", "value" => "bear_note", "description" => "", "value_type" => "text"}
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

  defp stage(socket, event) do
    bytes = Jason.encode!(event)
    transfer = Ecto.UUID.generate()

    ref =
      push(socket, "transfer_begin", %{
        "transfer_id" => transfer,
        "size_bytes" => byte_size(bytes),
        "checksum_sha256" => Protocol.sha256(bytes)
      })

    assert_reply(ref, :ok, %{})

    push(socket, "blob_chunk", %{
      "transfer_id" => transfer,
      "blob_id" => "event",
      "offset" => 0,
      "data" => Base.encode64(bytes)
    })

    ref = push(socket, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
    assert_reply(ref, :ok, %{})
    transfer
  end

  defp reply(socket, ref, response) do
    send(socket.channel_pid, %Phoenix.Socket.Message{
      join_ref: socket.join_ref,
      ref: ref,
      topic: socket.topic,
      event: "phx_reply",
      payload: %{"status" => "ok", "response" => response}
    })
  end

  defp collect_blob(socket, transfer, blob, parts) do
    receive do
      %Phoenix.Socket.Message{
        event: "blob_chunk",
        payload: %{
          "transfer_id" => ^transfer,
          "blob_id" => ^blob,
          "offset" => offset,
          "data" => data
        }
      } ->
        assert offset == IO.iodata_length(Enum.reverse(parts))
        bytes = Base.decode64!(data)
        assert byte_size(bytes) <= 65_536
        collect_blob(socket, transfer, blob, [bytes | parts])

      %Phoenix.Socket.Message{event: "blob_end", ref: ref, payload: %{"blob_id" => ^blob}} ->
        reply(socket, ref, %{})
        parts |> Enum.reverse() |> IO.iodata_to_binary()
    after
      2000 -> flunk("outbound blob stalled")
    end
  end
end
