defmodule GSMLG.AdminWeb.NoteSyncChannelTest do
  use GSMLG.AdminWeb.ChannelCase, async: false
  alias GSMLG.AdminWeb.{NoteSyncSocket, NoteSyncChannel}
  alias GSMLG.GaoNote.{Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}

  alias GSMLG.Storage.TestCatalogClient

  defmodule CommitBudgetStore do
    def put_file(_bucket, key, path, _mime) do
      objects = Application.fetch_env!(:gsmlg_storage, :commit_budget_objects)
      bytes = File.read!(path)
      Agent.update(objects, &Map.put(&1, key, bytes))
      :ok
    end
  end

  defmodule AttachmentObjectStub do
    import Plug.Conn

    def init(options), do: options

    def call(conn, options) do
      ["bytes=" <> bounds] = get_req_header(conn, "range")
      [first, last] = bounds |> String.split("-") |> Enum.map(&String.to_integer/1)
      send(options[:owner], {:attachment_range, self(), first, last})

      if first == 0 do
        receive do
          :continue_read -> :ok
        after
          30_000 -> raise "attachment read barrier timed out"
        end
      end

      send_resp(conn, 206, binary_part(options[:bytes], first, last - first + 1))
    end
  end

  setup do
    TestCatalogClient.setup!()
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
    {:ok, connected} = connect(NoteSyncSocket, %{})

    payload = %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }

    {:ok, response, socket} =
      subscribe_and_join(connected, NoteSyncChannel, "note_sync:v1", payload)

    Process.unlink(socket.channel_pid)
    guard = socket.assigns.guard

    on_exit(fn ->
      monitor = Process.monitor(guard)
      if Process.alive?(socket.channel_pid), do: Process.exit(socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5000
    end)

    %{
      peer: socket.assigns.session_peer,
      connected: connected,
      socket: socket,
      response: response,
      payload: payload
    }
  end

  test "anonymous join creates a peer and validates the protocol payload", context do
    assert context.socket.assigns.session_peer.actor_id == "note_sync:#{context.peer.id}"
    assert context.response["node_id"] != context.peer.id
    assert context.response["selectors"] == ["project=bear_note"]

    for invalid <- [
          Map.put(context.payload, "actor_id", "spoof"),
          Map.put(context.payload, "node_id", "invalid"),
          Map.put(context.payload, "selectors", []),
          Map.put(context.payload, "protocol_version", 2)
        ] do
      assert {:error, %{code: "invalid_join"}} =
               subscribe_and_join(context.connected, NoteSyncChannel, "note_sync:v1", invalid)
    end
  end

  test "committed inbound transfer preserves UUID and returns full ACK", %{
    socket: socket,
    peer: peer
  } do
    event = event(peer)
    transfer = stage(socket, event)
    ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
    expected = Protocol.ack(event)
    assert_reply(ref, :ok, ^expected, 1_000)
    assert_push("ack", ^expected, 1_000)
    assert %Note{id: id, title: "remote"} = GSMLG.Repo.get(Note, event["note_id"])
    assert id == event["note_id"]
    assert socket.assigns.session_peer.actor_id == "note_sync:#{peer.id}"
  end

  for {sizes, deadline} <- [
        {[], 62_000},
        {[0, 0], 72_000},
        {[10_449_995], 85_000},
        {List.duplicate(0, 168), 900_000}
      ] do
    @tag attachment_sizes: sizes, commit_deadline: deadline
    test "commit budget accounts for #{length(sizes)} attachments totalling #{Enum.sum(sizes)} bytes and drains durable work",
         %{socket: socket, peer: peer, attachment_sizes: sizes, commit_deadline: deadline} do
      attachments =
        sizes
        |> Enum.map(fn size -> {Ecto.UUID.generate(), :binary.copy("x", size)} end)
        |> Enum.sort_by(&elem(&1, 0))

      descriptors =
        Enum.map(attachments, fn {id, bytes} ->
          %{
            "id" => id,
            "path" => "#{id}.txt",
            "mime" => "text/plain",
            "description" => "",
            "size_bytes" => byte_size(bytes),
            "checksum_sha256" => Protocol.sha256(bytes)
          }
        end)

      event = put_in(event(peer), ["snapshot", "attachments"], descriptors)
      event = Map.put(event, "snapshot_hash", Protocol.snapshot_hash(event["snapshot"]))
      objects = commit_budget_barrier(event)
      transfer = stage(socket, event)

      Enum.each(attachments, fn {id, bytes} ->
        blob = "attachment:" <> id
        ref = push(socket, "attachment_begin", %{"transfer_id" => transfer, "blob_id" => blob})
        assert_reply(ref, :ok, %{}, 1_000)
        stage_chunks(socket, transfer, blob, bytes, 0)
        ref = push(socket, "blob_end", %{"transfer_id" => transfer, "blob_id" => blob})
        assert_reply(ref, :ok, %{}, 2000)
      end)

      incoming = channel_state(socket).assigns.incoming
      lease_id = Ecto.UUID.generate()
      Store.put("lease", lease_id, %{"session_id" => peer.session_id}, peer.id)
      ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
      task = channel_state(socket).assigns.apply_task
      task_monitor = Process.monitor(task.pid)
      guard_monitor = Process.monitor(socket.assigns.guard)

      try do
        assert Process.read_timer(task.timer) in (deadline - 2_000)..deadline
        assert_receive {:commit_budget_held, worker}, 10_000
        assert worker == task.pid
        heartbeat = push(socket, "inventory_complete", %{})
        assert_reply(heartbeat, :ok, %{}, 1_000)
        ack = Protocol.ack(event)
        refute_reply(ref, :ok, ^ack, 10)
        refute_push("ack", ^ack, 10)
        send(socket.channel_pid, {:task_deadline, make_ref()})
        assert channel_state(socket).assigns.apply_task.ref == task.ref
        monitor = Process.monitor(socket.channel_pid)
        send(socket.channel_pid, {:task_deadline, task.ref})
        assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
        refute_receive {:DOWN, ^task_monitor, :process, _, _}, 10
        assert Process.alive?(worker)
        assert Process.alive?(socket.assigns.guard)
        assert File.exists?(incoming.directory)
        assert File.exists?(socket.assigns.staging_root)
        assert Store.get("lease", lease_id, peer.id)
        assert Store.get("received", event["event_id"], peer.id) == nil

        send(worker, :release_commit_budget)
        assert_receive {:DOWN, ^task_monitor, :process, ^worker, :normal}, 5_000
        assert_receive {:DOWN, ^guard_monitor, :process, _, :normal}, 5_000
        assert %Note{id: id} = GSMLG.Repo.get(Note, event["note_id"])
        assert id == event["note_id"]

        assert Store.get("received", event["event_id"], peer.id) == %{
                 "event_hash" => Protocol.sha256(Protocol.canonical_json(event))
               }

        assert {:ok, ^ack} = Sync.apply(peer, event, Map.new(attachments))
        assert Agent.get(objects, &map_size(&1)) == length(attachments)
        assert Store.get("lease", lease_id, peer.id) == nil
        refute File.exists?(incoming.directory)
        refute File.exists?(socket.assigns.staging_root)
      after
        # Keep storage and Sandbox fixtures alive until any published apply settles,
        # including when an assertion fails before the normal release above.
        send(task.pid, :release_commit_budget)
        await_process_exit(task.pid)
        await_process_exit(socket.assigns.guard)
      end
    end
  end

  defp commit_budget_barrier(event) do
    objects = start_supervised!({Agent, fn -> %{} end})
    config = %{upload_s3_client: CommitBudgetStore, commit_budget_objects: objects}

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:gsmlg, :gao_note, :sync, :apply, :start],
      fn _, _, metadata, _ ->
        if metadata.event_id == event["event_id"] and metadata.phase == :transaction do
          send(owner, {:commit_budget_held, self()})

          receive do
            :release_commit_budget -> :ok
          after
            30_000 -> raise "commit budget barrier timed out"
          end
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    objects
  end

  defp await_process_exit(pid) do
    monitor = Process.monitor(pid)
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
  end

  test "commit cleanup stays within the task budget while the channel remains responsive", %{
    socket: socket,
    peer: peer
  } do
    event = event(peer)
    owner = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:gsmlg, :gao_note, :sync, :apply, :start],
        fn _, _, metadata, _ ->
          if metadata.phase == :transfer_cleanup and metadata.event_id == event["event_id"] do
            send(owner, {:cleanup_started, self()})

            receive do
              :continue_cleanup -> :ok
            after
              2000 -> raise "cleanup barrier timed out"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    transfer = stage(socket, event)
    ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
    assert_receive {:cleanup_started, worker}, 1000
    task = channel_state(socket).assigns.apply_task
    assert worker == task.pid
    assert Process.read_timer(task.timer) > 10_000
    heartbeat = push(socket, "inventory_complete", %{})
    assert_reply(heartbeat, :ok, %{}, 1_000)
    ack = Protocol.ack(event)
    refute_reply(ref, :ok, ^ack, 10)
    send(worker, :continue_cleanup)
    assert_reply(ref, :ok, ^ack, 1_000)
    assert_push("ack", ^ack, 1_000)
    assert Process.read_timer(task.timer) == false
  end

  test "commit before event finalization rejects normally", %{socket: socket, peer: peer} do
    bytes = Jason.encode!(event(peer))
    transfer = Ecto.UUID.generate()

    ref =
      push(socket, "transfer_begin", %{
        "transfer_id" => transfer,
        "size_bytes" => byte_size(bytes),
        "checksum_sha256" => Protocol.sha256(bytes)
      })

    assert_reply(ref, :ok, %{}, 1_000)
    monitor = Process.monitor(socket.channel_pid)
    push(socket, "transfer_commit", %{"transfer_id" => transfer})
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 1000
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

    assert_push(
      "note_rejected",
      %{
        "code" => "note_rejected",
        "event_id" => event_id,
        "note_id" => note_id,
        "reason" => "catalog_conflict"
      },
      1_000
    )

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
    assert_push("ack", ^expected, 1_000)
    assert GSMLG.Repo.get(Note, good["note_id"])
  end

  test "NUL note receives a definitive rejection at commit and the next note continues", %{
    socket: socket,
    peer: peer
  } do
    bad = put_in(event(peer), ["snapshot", "content"], "body" <> <<0>>)
    bad = Map.put(bad, "snapshot_hash", Protocol.snapshot_hash(bad["snapshot"]))
    transfer = stage(socket, bad)
    ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})

    expected = %{
      "code" => "note_rejected",
      "event_id" => bad["event_id"],
      "note_id" => bad["note_id"],
      "reason" => "validation_failed"
    }

    assert_reply(ref, :error, ^expected, 1_000)
    refute GSMLG.Repo.get(Note, bad["note_id"])
    refute GSMLG.GaoNote.Sync.Store.get("received", bad["event_id"], peer.id)
    assert Process.alive?(socket.channel_pid)

    transfer = stage(socket, bad)

    send(socket.channel_pid, %Phoenix.Socket.Message{
      join_ref: socket.join_ref,
      ref: nil,
      topic: socket.topic,
      event: "transfer_commit",
      payload: %{"transfer_id" => transfer}
    })

    assert_push("note_rejected", ^expected, 1_000)
    refute GSMLG.GaoNote.Sync.Store.get("received", bad["event_id"], peer.id)

    good = event(peer)
    transfer = stage(socket, good)
    ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
    ack = Protocol.ack(good)
    assert_reply(ref, :ok, ^ack, 2000)
    assert_push("ack", ^ack, 1_000)
    assert %Note{content: "body"} = GSMLG.Repo.get(Note, good["note_id"])
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
    assert_reply(ref, :ok, %{}, 1_000)

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
    assert_reply(commit_ref, :ok, ^ack, 2000)
    assert_push("ack", ^ack, 1_000)
    reply(socket, begin_ref, %{})
    metadata = collect_blob(socket, begin_payload["transfer_id"], "event", [])
    outgoing = Jason.decode!(metadata)
    assert outgoing["note_id"] == note.id
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: commit_ref}, 2000
    reply(socket, commit_ref, Protocol.ack(outgoing))
    assert_push("inventory_complete", %{}, 2000)
    assert Sync.pending(peer.id) == []
  end

  test "snapshot failures log bounded diagnostics and retain the note while the session continues",
       %{
         socket: socket,
         peer: peer
       } do
    {:ok, note} =
      Compat.save_note(
        %{
          title: "private diagnostic title",
          content: "private diagnostic content",
          labels: [["project", "bear_note"]]
        },
        nil
      )

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: Ecto.UUID.generate(),
      note_id: note.id,
      storage_file_id: Ecto.UUID.generate(),
      path: "./private-diagnostic-path.txt",
      mime: "text/plain"
    })

    capture_log_telemetry()
    monitor = Process.monitor(socket.channel_pid)
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 1_000)

    assert_receive {:telemetry, [:gsmlg, :log], %{level: :error},
                    %{message: "GaoNote sync operation failed"} = metadata},
                   2000

    assert metadata == %{
             message: "GaoNote sync operation failed",
             operation: :checkout,
             reason: :object_unavailable,
             peer_id: peer.id,
             note_id: note.id,
             failure_scope: :note,
             retry_in_ms: 5000,
             attempt: 1
           }

    refute_receive {:DOWN, ^monitor, :process, _, _}, 50
    heartbeat = push(socket, "inventory_complete", %{})
    assert_reply(heartbeat, :ok, %{}, 1_000)
    assert Store.get("pending", note.id, peer.id)
    assert [] = Store.list("lease", peer.id)
  end

  test "attachment read diagnostics retain identifiers without logging raw upstream responses", %{
    peer: peer
  } do
    capture_log_telemetry()
    ref = make_ref()
    note_id = Ecto.UUID.generate()
    storage_id = Ecto.UUID.generate()

    socket = %Phoenix.Socket{
      assigns: %{
        session_peer: peer,
        guard: self(),
        outgoing: nil,
        incoming: nil,
        read_task: %{
          ref: ref,
          pid: self(),
          timer: make_ref(),
          note_id: note_id,
          storage_file_id: storage_id
        }
      }
    }

    reason = {:unexpected_response, %{status_code: 403, body: "private upstream response"}}

    assert {:stop, {:shutdown, :sync_session_error}, _socket} =
             NoteSyncChannel.handle_info({ref, {:error, reason}}, socket)

    assert_receive {:telemetry, [:gsmlg, :log], %{level: :error}, metadata}

    assert metadata == %{
             message: "GaoNote sync operation failed",
             operation: :read,
             reason: :unexpected_response,
             peer_id: peer.id,
             note_id: note_id,
             storage_file_id: storage_id
           }
  end

  test "blocked inventory coalesces requests and still services inbound frames and task deadlines",
       %{socket: socket, peer: peer} do
    capture_log_telemetry()
    blocker = hold_database()

    try do
      ref = push(socket, "inventory_start", %{})
      task = channel_state(socket).assigns.inventory_task
      assert is_pid(task.pid)
      assert Process.read_timer(task.timer) in 1..10_000
      duplicate = push(socket, "inventory_start", %{})
      assert_reply(duplicate, :ok, %{}, 1_000)
      assert channel_state(socket).assigns.inventory_task.ref == task.ref
      refute_reply(ref, :ok, %{}, 10)
      stage(socket, event(peer))
      assert channel_state(socket).assigns.incoming.event["kind"] == "attach"
      monitor = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, {:task_deadline, task.ref})

      assert_receive {:telemetry, [:gsmlg, :log], %{level: :error},
                      %{
                        message: "GaoNote sync operation failed",
                        operation: :inventory,
                        reason: :task_timeout,
                        peer_id: peer_id
                      }}

      assert peer_id == peer.id
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

  test "a busy pending poll reschedules without altering transfers or their leases", %{peer: peer} do
    ref = make_ref()
    timer = Process.send_after(self(), :unused_pending_deadline, 10_000)
    outgoing = %{lease: Ecto.UUID.generate(), phase: :preparing}

    socket = %Phoenix.Socket{
      assigns: %{
        session_peer: peer,
        guard: self(),
        pending_task: %{ref: ref, pid: self(), timer: timer},
        queue: ["existing"],
        outgoing: outgoing
      }
    }

    assert {:noreply, updated} = NoteSyncChannel.handle_info({ref, {:ok, :busy}}, socket)
    assert updated.assigns.pending_task == nil
    assert updated.assigns.outgoing == outgoing
    assert updated.assigns.queue == ["existing"]
    assert Process.read_timer(timer) == false
    assert_receive :poll_pending, 1500
    refute_receive :send_next, 10
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

    assert_reply(ref, :ok, %{}, 1_000)

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
      assert_reply(heartbeat, :ok, %{}, 1_000)
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

  for {size, deadline} <- [{0, 30_000}, {10_449_995, 40_000}, {536_869_000, 542_000}] do
    @tag attachment_size: size, read_deadline: deadline
    test "a #{size}-byte attachment has a bounded read deadline and keeps its lease until confirmed",
         %{socket: socket, peer: peer, attachment_size: size, read_deadline: deadline} do
      attachment_server("")

      {:ok, note} =
        Compat.save_note(
          %{title: "attachment", content: "body", labels: [["project", "bear_note"]]},
          nil
        )

      file =
        TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
          tenant: "gao_note",
          type: "attachment",
          filename: "x.txt",
          s3_key: Ecto.UUID.generate(),
          content_type: "text/plain",
          size: size,
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
      assert_reply(ref, :ok, %{}, 1_000)

      assert_receive {:attachment_range, _reader, 0, _last}, 2000
      refute_receive %Phoenix.Socket.Message{event: "transfer_begin"}, 10
      state = channel_state(socket)
      outgoing = state.assigns.outgoing.event
      task = state.assigns.read_task
      assert Process.read_timer(task.timer) in (deadline - 2_000)..deadline
      send(socket.channel_pid, {:task_deadline, make_ref()})
      assert channel_state(socket).assigns.read_task.ref == task.ref
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
      task_monitor = Process.monitor(task.pid)
      send(socket.channel_pid, {:task_deadline, state.assigns.read_task.ref})
      assert_receive {:DOWN, ^task_monitor, :process, _, _}, 1000
      recovered = await_state(socket, &is_nil(&1.assigns.outgoing))
      assert Process.alive?(socket.assigns.guard)
      assert recovered.assigns.preparation_timer == nil
      assert recovered.assigns.read_task == nil
      refute File.exists?(state.assigns.outgoing.directory)
      refute Store.get("lease", lease, peer.id)
      assert Store.get("pending", note.id, peer.id)
      retry = recovered.assigns.preparation_retries[note.id]
      assert retry.reason == :task_timeout
      assert retry.attempts == 1
      assert retry.retry_at > System.monotonic_time(:millisecond)

      # A cancelled worker can race its deadline with an already sent result.
      send(socket.channel_pid, {task.ref, {:ok, %{path: "stale", size: 0}}})
      send(socket.channel_pid, {:task_deadline, task.ref})
      send(socket.channel_pid, {:preparation_deadline, elem(state.assigns.preparation_timer, 0)})
      heartbeat = push(socket, "inventory_complete", %{})
      assert_reply(heartbeat, :ok, %{}, 1_000)

      if size == 0 do
        :sys.replace_state(socket.channel_pid, fn current ->
          put_in(
            current.assigns.preparation_retries[note.id].retry_at,
            System.monotonic_time(:millisecond) - 1
          )
        end)

        send(socket.channel_pid, :poll_pending)
        assert_receive {:attachment_range, _reader, 0, _last}, 2000
        retry_task = channel_state(socket).assigns.read_task
        refute retry_task.ref == task.ref
        send(socket.channel_pid, {:task_deadline, retry_task.ref})
        recovered = await_state(socket, &is_nil(&1.assigns.outgoing))
        retry = recovered.assigns.preparation_retries[note.id]
        assert retry.attempts == 2
        assert (retry.retry_at - System.monotonic_time(:millisecond)) in 8_000..10_000

        :sys.replace_state(socket.channel_pid, fn current ->
          retry = %{retry | attempts: 20, retry_at: System.monotonic_time(:millisecond) - 1}
          put_in(current.assigns.preparation_retries[note.id], retry)
        end)

        send(socket.channel_pid, :poll_pending)
        assert_receive {:attachment_range, _reader, 0, _last}, 2000
        retry_task = channel_state(socket).assigns.read_task
        send(socket.channel_pid, {:task_deadline, retry_task.ref})
        recovered = await_state(socket, &is_nil(&1.assigns.outgoing))
        retry = recovered.assigns.preparation_retries[note.id]
        assert retry.attempts == 21
        assert (retry.retry_at - System.monotonic_time(:millisecond)) in 298_000..300_000
      end
    end
  end

  test "outbound attachment reads renew leases and preserve wire chunks through completion", %{
    socket: socket,
    peer: peer
  } do
    bytes = :binary.copy("attachment", 1_044_999) <> "final"

    attachment_server(bytes)

    {:ok, note} =
      Compat.save_note(
        %{title: "attachment", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    file =
      TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
        tenant: "gao_note",
        type: "attachment",
        filename: "attachment.pdf",
        s3_key: Ecto.UUID.generate(),
        content_type: "application/pdf",
        size: byte_size(bytes),
        checksum: Protocol.sha256(bytes)
      })

    attachment_id = Ecto.UUID.generate()

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: attachment_id,
      note_id: note.id,
      storage_file_id: file.id,
      path: "./attachment.pdf",
      mime: "application/pdf"
    })

    {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "attachment body"}, nil)
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)

    assert_receive {:attachment_range, reader, 0, 4_194_303}, 2000
    refute_receive %Phoenix.Socket.Message{event: "transfer_begin"}, 10

    state = channel_state(socket)
    task = state.assigns.read_task
    lease_id = state.assigns.outgoing.lease
    lease = Store.get("lease", lease_id, peer.id)
    short_expiry = System.system_time(:millisecond) + 5_000
    Store.put("lease", lease_id, Map.put(lease, "expires_at", short_expiry), peer.id, note.id)
    send(socket.channel_pid, :poll_pending)

    state =
      await_state(socket, fn _ ->
        Store.get("lease", lease_id, peer.id)["expires_at"] > short_expiry + 30_000
      end)

    assert state.assigns.outgoing.phase == :preparing
    assert state.assigns.read_task.ref == task.ref
    heartbeat = push(socket, "inventory_complete", %{})
    assert_reply(heartbeat, :ok, %{}, 1_000)
    send(reader, :continue_read)

    assert_receive %Phoenix.Socket.Message{event: "transfer_begin", ref: ref, payload: payload},
                   2000

    staged = channel_state(socket).assigns.outgoing
    assert File.exists?(staged.directory)
    assert Bitwise.band(File.stat!(staged.directory).mode, 0o777) == 0o700

    assert Enum.all?(staged.prepared, fn {_id, file} ->
             Bitwise.band(File.stat!(file.path).mode, 0o777) == 0o600
           end)

    stop_supervised!(Bandit)
    begin_timer = channel_state(socket).assigns.waiting.timer
    assert Process.read_timer(begin_timer) in 1..10_000
    reply(socket, ref, %{})
    outgoing = socket |> collect_blob(payload["transfer_id"], "event", []) |> Jason.decode!()
    assert Process.read_timer(begin_timer) == false
    assert_receive %Phoenix.Socket.Message{event: "attachment_begin", ref: ref}, 2000
    assert Process.read_timer(task.timer) == false
    send(socket.channel_pid, {:task_deadline, task.ref})
    reply(socket, ref, %{})

    assert collect_blob(socket, payload["transfer_id"], "attachment:" <> attachment_id, []) ==
             bytes

    assert_receive {:attachment_range, _, 4_194_304, 8_388_607}
    assert_receive {:attachment_range, _, 8_388_608, 10_449_994}
    refute_received {:attachment_range, _, _, _}
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: ref}, 2000
    waiting = channel_state(socket).assigns.waiting
    assert Process.read_timer(waiting.timer) in 113_000..115_000
    ack = Protocol.ack(outgoing)
    push(socket, "ack", Map.put(ack, "event_id", Ecto.UUID.generate()))
    assert channel_state(socket).assigns.waiting == waiting
    reply(socket, ref, ack)
    await_state(socket, fn _ -> Store.get("ack", lease_id, peer.id) == ack end)
    assert Process.read_timer(waiting.timer) == false
    send(socket.channel_pid, {:request_deadline, waiting.ref})
    heartbeat = push(socket, "inventory_complete", %{})
    assert_reply(heartbeat, :ok, %{}, 1_000)
    assert Sync.pending(peer.id) == []
    await_state(socket, &is_nil(&1.assigns.outgoing))
    refute File.exists?(staged.directory)
  end

  for outcome <- [:ack, :rejection, :deadline, :read_error, :task_exit, :disconnect] do
    @tag preparation_outcome: outcome
    test "all attachments finish preparation before announcement and clean up after #{outcome}",
         %{
           socket: socket,
           peer: peer,
           preparation_outcome: outcome
         } do
      bytes = "prepared attachment"
      attachment_server(bytes)

      {:ok, note} =
        Compat.save_note(
          %{title: "slow preparation", content: "body", labels: [["project", "bear_note"]]},
          nil
        )

      file =
        TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
          tenant: "gao_note",
          type: "attachment",
          filename: "private.txt",
          s3_key: Ecto.UUID.generate(),
          content_type: "text/plain",
          size: byte_size(bytes),
          checksum: Protocol.sha256(bytes)
        })

      ids = Enum.sort([Ecto.UUID.generate(), Ecto.UUID.generate()])

      Enum.each(ids, fn id ->
        attachment_file =
          TestCatalogClient.insert_file!(%{
            file
            | id: Ecto.UUID.generate(),
              s3_key: Ecto.UUID.generate()
          })

        GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
          id: Ecto.UUID.generate(),
          api_id: id,
          note_id: note.id,
          storage_file_id: attachment_file.id,
          path: "./#{id}.txt",
          mime: "text/plain"
        })
      end)

      {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "with attachments"}, nil)

      if outcome in [:ack, :rejection] do
        :sys.replace_state(socket.channel_pid, fn current ->
          retry = %{
            attempts: 1,
            reason: :task_timeout,
            retry_at: System.monotonic_time(:millisecond) - 1
          }

          put_in(current.assigns.preparation_retries[note.id], retry)
        end)
      end

      ref = push(socket, "inventory_start", %{})
      assert_reply(ref, :ok, %{}, 1_000)
      assert_receive {:attachment_range, first, 0, _last}, 2000
      state = channel_state(socket)
      lease_id = state.assigns.outgoing.lease
      initial_expiry = Store.get("lease", lease_id, peer.id)["expires_at"]
      assert Process.read_timer(elem(state.assigns.preparation_timer, 1)) > 10_000

      refute_receive %Phoenix.Socket.Message{event: "transfer_begin"},
                     if(outcome == :ack, do: 10_100, else: 10)

      assert Process.alive?(socket.channel_pid)

      if outcome == :ack do
        assert Store.get("lease", lease_id, peer.id)["expires_at"] > initial_expiry + 8_000
      end

      heartbeat = push(socket, "inventory_complete", %{})
      assert_reply(heartbeat, :ok, %{}, 1_000)
      send(first, :continue_read)
      assert_receive {:attachment_range, second, 0, _last}, 2000
      refute_receive %Phoenix.Socket.Message{event: "transfer_begin"}, 50
      partial = channel_state(socket).assigns.outgoing
      assert map_size(partial.prepared) == 1

      if outcome in [:deadline, :read_error, :task_exit, :disconnect] do
        task = channel_state(socket).assigns.read_task
        task_monitor = Process.monitor(task.pid)

        case outcome do
          :deadline ->
            send(socket.channel_pid, {:preparation_deadline, make_ref()})
            assert channel_state(socket).assigns.outgoing == partial
            {token, _timer} = channel_state(socket).assigns.preparation_timer
            send(socket.channel_pid, {:preparation_deadline, token})

          :read_error ->
            send(socket.channel_pid, {task.ref, {:error, :object_integrity_mismatch}})

          :task_exit ->
            Process.exit(task.pid, :kill)

          :disconnect ->
            Process.exit(socket.channel_pid, :shutdown)
        end

        assert_receive {:DOWN, ^task_monitor, :process, _, _}, 2000

        if outcome == :disconnect do
          guard_monitor = Process.monitor(socket.assigns.guard)
          assert_receive {:DOWN, ^guard_monitor, :process, _, _}, 2000
        else
          recovered = await_state(socket, &is_nil(&1.assigns.outgoing))
          assert Process.alive?(socket.assigns.guard)
          assert recovered.assigns.preparation_retries[note.id].attempts == 1
          assert Store.get("pending", note.id, peer.id)
          heartbeat = push(socket, "inventory_complete", %{})
          assert_reply(heartbeat, :ok, %{}, 1_000)
        end

        refute File.exists?(partial.directory)
        assert Store.get("lease", lease_id, peer.id) == nil
        refute_received %Phoenix.Socket.Message{event: "transfer_begin"}
        send(second, :continue_read)
      else
        send(second, :continue_read)

        assert_receive %Phoenix.Socket.Message{
                         event: "transfer_begin",
                         ref: ref,
                         payload: payload
                       },
                       2000

        prepared = channel_state(socket).assigns.outgoing
        assert map_size(prepared.prepared) == 2
        assert channel_state(socket).assigns.preparation_timer == nil
        stop_supervised!(Bandit)
        reply(socket, ref, %{})
        event = socket |> collect_blob(payload["transfer_id"], "event", []) |> Jason.decode!()

        Enum.each(ids, fn id ->
          assert_receive %Phoenix.Socket.Message{event: "attachment_begin", ref: ref}, 2000
          reply(socket, ref, %{})
          assert collect_blob(socket, payload["transfer_id"], "attachment:" <> id, []) == bytes
        end)

        assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: ref}, 2000

        if outcome == :ack do
          reply(socket, ref, Protocol.ack(event))
        else
          push(socket, "note_rejected", %{
            "code" => "note_rejected",
            "event_id" => event["event_id"],
            "note_id" => note.id,
            "reason" => "validation_failed"
          })
        end

        assert_push("inventory_complete", %{}, 2000)
        refute Map.has_key?(channel_state(socket).assigns.preparation_retries, note.id)
        refute File.exists?(prepared.directory)
        refute_received {:attachment_range, _, _, _}
      end
    end
  end

  test "pushed committed ACK is accepted before the commit request reply", %{socket: socket} do
    {:ok, _} =
      Compat.save_note(
        %{title: "local", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 1_000)

    assert_receive %Phoenix.Socket.Message{
                     event: "transfer_begin",
                     ref: begin_ref,
                     payload: payload
                   },
                   2000

    reply(socket, begin_ref, %{})
    outgoing = socket |> collect_blob(payload["transfer_id"], "event", []) |> Jason.decode!()
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: commit_ref}, 2000
    waiting = channel_state(socket).assigns.waiting
    assert Process.read_timer(waiting.timer) in 90_000..92_000
    push(socket, "ack", Protocol.ack(outgoing))
    assert_push("inventory_complete", %{}, 2000)
    assert Process.read_timer(waiting.timer) == false
    reply(socket, commit_ref, Protocol.ack(outgoing))
    ref = push(socket, "inventory_complete", %{})
    assert_reply(ref, :ok, %{}, 1_000)
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
    assert_reply(ref, :ok, %{}, 1_000)

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

  defp attachment_server(bytes) do
    server =
      start_supervised!(
        {Bandit,
         plug: {AttachmentObjectStub, owner: self(), bytes: bytes}, port: 0, startup_log: false},
        id: Bandit
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    keys = [:s3_bucket, :s3_endpoint]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    Application.put_env(:gsmlg_storage, :s3_bucket, "channel-read-test")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    server
  end

  defp capture_log_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:gsmlg, :log],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
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

    assert_reply(ref, :ok, %{}, 1_000)

    push(socket, "blob_chunk", %{
      "transfer_id" => transfer,
      "blob_id" => "event",
      "offset" => 0,
      "data" => Base.encode64(bytes)
    })

    ref = push(socket, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
    assert_reply(ref, :ok, %{}, 1_000)
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

  defp stage_chunks(_socket, _transfer, _blob, <<>>, _offset), do: :ok

  defp stage_chunks(socket, transfer, blob, bytes, offset) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(size), rest::binary>> = bytes

    push(socket, "blob_chunk", %{
      "transfer_id" => transfer,
      "blob_id" => blob,
      "offset" => offset,
      "data" => Base.encode64(chunk)
    })

    stage_chunks(socket, transfer, blob, rest, offset + size)
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
