defmodule GSMLG.AdminWeb.NoteSyncTasksChannelTest do
  use GSMLG.AdminWeb.NoteSyncAutoCase, async: false
  alias GSMLG.AdminWeb.{NoteSyncChannel, NoteSyncSocket}
  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}

  setup %{label: label} do
    GSMLG.Storage.TestCatalogClient.setup!()
    {:ok, connected} = connect(NoteSyncSocket, %{})
    peer_id = Ecto.UUID.generate()

    {:ok, response, socket} =
      subscribe_and_join(connected, NoteSyncChannel, "note_sync:v1", %{
        "protocol_version" => 1,
        "node_id" => peer_id,
        "selectors" => [label <> "=selected"],
        "max_blob_bytes" => 536_870_912
      })

    assert response["capabilities"] == ["state_query_v1", "task_sync_v1"]
    Process.unlink(socket.channel_pid)

    on_exit(fn ->
      monitor = Process.monitor(socket.assigns.guard)
      if Process.alive?(socket.channel_pid), do: Process.exit(socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    end)

    caps = %{"capabilities" => ["state_query_v1", "task_sync_v1"]}
    ref = push(socket, "sync_negotiate", caps)
    assert_reply(ref, :ok, ^caps)
    %{socket: socket, peer: socket.assigns.session_peer}
  end

  test "multi-chunk metadata replays without appending twice and commits only once", %{
    socket: socket,
    peer: peer
  } do
    event = event(peer, String.duplicate("data", 40_000))
    bytes = Jason.encode!(event)
    transfer = Ecto.UUID.generate()

    assert done(socket, 1, "transfer_begin", %{
             "transfer_id" => transfer,
             "size_bytes" => byte_size(bytes),
             "checksum_sha256" => Protocol.sha256(bytes)
           }) == %{}

    {sequence, _} =
      chunks(bytes)
      |> Enum.reduce({2, 0}, fn chunk, {sequence, offset} ->
        payload = %{
          "transfer_id" => transfer,
          "blob_id" => "event",
          "offset" => offset,
          "data" => Base.encode64(chunk)
        }

        expected = %{
          "transfer_id" => transfer,
          "blob_id" => "event",
          "received_bytes" => offset + byte_size(chunk)
        }

        assert done(socket, sequence, "blob_chunk", payload) == expected
        id = "#{peer.id}:#{sequence}"
        push(socket, "task_submit", command(socket, sequence, "blob_chunk", payload))

        assert_push("task_status", %{
          "task_id" => ^id,
          "state" => "succeeded",
          "result" => ^expected
        })

        push(
          socket,
          "task_submit",
          command(socket, sequence, "blob_chunk", %{payload | "offset" => offset + 1})
        )

        assert_push("task_error", %{"task_id" => ^id, "code" => "task_id_conflict"})
        {sequence + 1, offset + byte_size(chunk)}
      end)

    assert done(socket, sequence, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"}) ==
             %{}

    ack = Protocol.ack(event)
    assert done(socket, sequence + 1, "transfer_commit", %{"transfer_id" => transfer}) == ack

    push(
      socket,
      "task_submit",
      command(socket, sequence + 1, "transfer_commit", %{"transfer_id" => transfer})
    )

    id = "#{peer.id}:#{sequence + 1}"
    assert_push("task_status", %{"task_id" => ^id, "state" => "succeeded", "result" => ^ack})

    assert GSMLG.Repo.get!(GSMLG.GaoNote.Note, event["note_id"]).content ==
             event["snapshot"]["content"]

    assert Store.get("received", event["event_id"], peer.id) != nil
    assert Process.alive?(socket.channel_pid)
  end

  test "failed transfer cleans its staging and the next note succeeds on the same channel", %{
    socket: socket,
    peer: peer
  } do
    event = event(peer, "next")
    bytes = Jason.encode!(event)
    first = Ecto.UUID.generate()

    done(socket, 1, "transfer_begin", %{
      "transfer_id" => first,
      "size_bytes" => byte_size(bytes),
      "checksum_sha256" => Protocol.sha256(bytes)
    })

    directory = state(socket).assigns.incoming.directory
    id = "#{peer.id}:2"

    push(
      socket,
      "task_submit",
      command(socket, 2, "blob_chunk", %{
        "transfer_id" => first,
        "blob_id" => "event",
        "offset" => 99,
        "data" => Base.encode64(bytes)
      })
    )

    assert_push(
      "task_status",
      %{
        "task_id" => ^id,
        "state" => "failed",
        "error" => %{"code" => "validation_failed", "retryable" => false}
      },
      2_000
    )

    refute File.exists?(directory)
    assert state(socket).assigns.incoming == nil
    transfer = Ecto.UUID.generate()

    done(socket, 3, "transfer_begin", %{
      "transfer_id" => transfer,
      "size_bytes" => byte_size(bytes),
      "checksum_sha256" => Protocol.sha256(bytes)
    })

    done(socket, 4, "blob_chunk", %{
      "transfer_id" => transfer,
      "blob_id" => "event",
      "offset" => 0,
      "data" => Base.encode64(bytes)
    })

    done(socket, 5, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
    assert done(socket, 6, "transfer_commit", %{"transfer_id" => transfer}) == Protocol.ack(event)
    assert Process.alive?(socket.channel_pid)
  end

  test "outbound chunks wait for confirmed offsets and retain pending until the exact ACK", %{
    socket: socket,
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(
        %{
          title: "outgoing",
          content: String.duplicate("z", 150_000),
          labels: [String.split(hd(peer.selectors), "=", parts: 2)]
        },
        nil
      )

    done(socket, 1, "inventory_start", %{})
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: query}, 2_000
    assert query["operation"] == "state_query"
    [descriptor] = query["payload"]["items"]

    settle(socket, query, %{
      "query_id" => query["payload"]["query_id"],
      "items" => [
        %{"requested" => descriptor, "association" => "missing", "member" => nil, "head" => nil}
      ]
    })

    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: begin}, 2_000
    assert begin["operation"] == "transfer_begin"
    assert state(socket).assigns.sync_manager.planned_notes == 1
    settle(socket, begin, %{})
    bytes = receive_chunks(socket, [])
    outgoing = Jason.decode!(bytes)
    assert outgoing["note_id"] == note.id
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: commit}, 2_000
    assert commit["operation"] == "transfer_commit"
    assert Sync.pending(peer.id) != []
    settle(socket, commit, Protocol.ack(outgoing))
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: complete}, 2_000
    assert complete["operation"] == "inventory_complete"
    settle(socket, complete, %{})
    assert Sync.pending(peer.id) == []
    marker = Path.join([state(socket).assigns.sync_manager.directory, "classifications", note.id])
    assert File.read!(marker) == "delivered"
    assert_push("sync_manager_status", %{"progress" => %{"planned_notes" => 1}}, 2_000)
    assert Process.alive?(socket.channel_pid)
  end

  test "manager publishes equal and blocked classifications without retransmitting equal notes",
       %{
         socket: socket,
         peer: peer
       } do
    notes =
      for _ <- 1..2 do
        {:ok, note} =
          Compat.save_note(
            %{
              title: "classification",
              content: "body",
              labels: [String.split(hd(peer.selectors), "=", parts: 2)]
            },
            nil
          )

        {:ok, lease} = Sync.checkout(peer, note.id)
        :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
        note
      end

    [equal, blocked] = notes
    member = Store.get("member", blocked.id, peer.id)

    Store.put(
      "member",
      blocked.id,
      Map.put(member, "rejected_event_id", member["event"]["event_id"]),
      peer.id,
      blocked.id
    )

    done(socket, 1, "inventory_start", %{})
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: query}, 2_000
    assert query["operation"] == "state_query"
    [descriptor] = query["payload"]["items"]
    assert descriptor["note_id"] == equal.id

    settle(socket, query, %{
      "query_id" => query["payload"]["query_id"],
      "items" => [equal_item(descriptor)]
    })

    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: complete}, 2_000
    assert complete["operation"] == "inventory_complete"
    settle(socket, complete, %{})

    assert_push(
      "sync_manager_status",
      %{
        "progress" => %{
          "checked_notes" => 2,
          "equal_notes" => 1,
          "planned_notes" => 1,
          "superseded_notes" => 0,
          "blocked_notes" => 1
        }
      },
      2_000
    )

    refute_receive %Phoenix.Socket.Message{
                     event: "task_submit",
                     payload: %{"operation" => "transfer_begin"}
                   },
                   50
  end

  test "manager classifies a stale queried descriptor as superseded without claiming equality", %{
    socket: socket,
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(
        %{
          title: "stale",
          content: "before",
          labels: [String.split(hd(peer.selectors), "=", parts: 2)]
        },
        nil
      )

    {:ok, lease} = Sync.checkout(peer, note.id)
    :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    done(socket, 1, "inventory_start", %{})
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: query}, 2_000
    [descriptor] = query["payload"]["items"]
    {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "after"}, nil)

    settle(socket, query, %{
      "query_id" => query["payload"]["query_id"],
      "items" => [equal_item(descriptor)]
    })

    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: complete}, 2_000
    assert complete["operation"] == "inventory_complete"

    assert_push(
      "sync_manager_status",
      %{"progress" => %{"superseded_notes" => 1, "equal_notes" => 0}},
      2_000
    )

    assert Sync.pending(peer.id) != []
  end

  @tag timeout: 120_000
  test "two compared pages cannot outrun coalesced source progress while page three is blocked",
       %{socket: socket, peer: peer} do
    notes =
      Enum.map(1..96, fn index ->
        {:ok, note} =
          Compat.save_note(
            %{
              title: "equal #{index}",
              content: "body",
              labels: [String.split(hd(peer.selectors), "=", parts: 2)]
            },
            nil
          )

        {:ok, lease} = Sync.checkout(peer, note.id)
        :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
        note.id
      end)

    third_cursor = notes |> Enum.sort() |> Enum.at(63) |> Ecto.UUID.dump!()
    owner = self()
    handler = {__MODULE__, make_ref()}
    held = :atomics.new(1, [])

    :telemetry.attach(
      handler,
      [:gsmlg, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ") cohort") do
          # Force the legitimate coalescing case independently of machine speed.
          # Terminal source completion still emits immediately.
          if Enum.at(metadata.params, 1),
            do:
              Process.put(:inventory_progress_at, System.monotonic_time(:millisecond) + 1_000_000)

          if Enum.at(metadata.params, 1) == third_cursor and
               :atomics.compare_exchange(held, 1, 0, 1) == :ok do
            send(owner, {:third_page_blocked, self()})

            receive do
              :release_source -> :ok
            after
              30_000 -> raise "third source page barrier timed out"
            end
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    id = "#{peer.id}:1"
    push(socket, "task_submit", command(socket, 1, "inventory_start", %{}))
    assert_receive {:third_page_blocked, producer}, 10_000

    try do
      Enum.each(1..64, fn _ ->
        assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: query}, 5_000
        assert query["operation"] == "state_query"
        [descriptor] = query["payload"]["items"]

        settle(socket, query, %{
          "query_id" => query["payload"]["query_id"],
          "items" => [
            %{
              "requested" => descriptor,
              "association" => "attached",
              "member" => descriptor,
              "head" => %{
                "version" => descriptor["version"],
                "snapshot_hash" => descriptor["snapshot_hash"],
                "attachments_available" => true
              }
            }
          ]
        })
      end)

      current = await_manager(socket, &(&1.pages_checked == 2))
      assert current.source["pages_scanned"] == 2
      assert current.source["notes_scanned"] == 64
      refute current.source["scan_complete"]
      old = %{current.source | "pages_scanned" => 1, "notes_scanned" => 32}
      send(socket.channel_pid, {:wire_progress, id, old})
      assert state(socket).assigns.sync_manager.source["pages_scanned"] == 2
      assert state(socket).assigns.sync_manager.source["notes_scanned"] == 64
      assert Process.alive?(socket.channel_pid)
      send(producer, :release_source)
      assert_push("task_status", %{"task_id" => ^id, "state" => "succeeded"}, 5_000)
    after
      send(producer, :release_source)
    end
  end

  defp await_manager(socket, predicate, attempts \\ 200)

  defp await_manager(socket, predicate, attempts) when attempts > 0 do
    manager = state(socket).assigns.sync_manager

    if predicate.(manager),
      do: manager,
      else:
        (
          Process.sleep(10)
          await_manager(socket, predicate, attempts - 1)
        )
  end

  defp await_manager(socket, predicate, 0) do
    manager = state(socket).assigns.sync_manager
    assert predicate.(manager)
    manager
  end

  for disconnect <- [false, true] do
    @tag disconnect: disconnect
    test "durable apply settles after cancellation or disconnect (disconnect=#{disconnect})", %{
      socket: socket,
      peer: peer,
      disconnect: disconnect
    } do
      event = event(peer, "durable")
      bytes = Jason.encode!(event)
      transfer = Ecto.UUID.generate()

      done(socket, 1, "transfer_begin", %{
        "transfer_id" => transfer,
        "size_bytes" => byte_size(bytes),
        "checksum_sha256" => Protocol.sha256(bytes)
      })

      done(socket, 2, "blob_chunk", %{
        "transfer_id" => transfer,
        "blob_id" => "event",
        "offset" => 0,
        "data" => Base.encode64(bytes)
      })

      done(socket, 3, "blob_end", %{"transfer_id" => transfer, "blob_id" => "event"})
      root = socket.assigns.staging_root
      directory = state(socket).assigns.incoming.directory
      owner = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:gsmlg, :gao_note, :sync, :apply, :start],
        fn _, _, metadata, _ ->
          if metadata.event_id == event["event_id"] and metadata.phase == :transaction do
            send(owner, {:apply_started, self()})

            receive do
              :release_apply -> :ok
            after
              30_000 -> raise "apply barrier timed out"
            end
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      id = "#{peer.id}:4"

      push(
        socket,
        "task_submit",
        command(socket, 4, "transfer_commit", %{"transfer_id" => transfer})
      )

      assert_receive {:apply_started, worker}, 2_000

      try do
        if disconnect do
          monitor = Process.monitor(worker)
          Process.exit(socket.channel_pid, :shutdown)
          Process.sleep(50)
          assert Process.alive?(worker)
          assert File.exists?(directory)
          assert File.exists?(root)
          send(worker, :release_apply)
          assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
          guard = Process.monitor(socket.assigns.guard)
          assert_receive {:DOWN, ^guard, :process, _, _}, 5_000
          refute File.exists?(root)
          assert Store.get("received", event["event_id"], peer.id) != nil
        else
          Process.sleep(10_100)
          push(socket, "task_cancel", %{"task_id" => id})

          assert_push(
            "task_status",
            %{"task_id" => ^id, "state" => "running", "phase" => "cancellation_pending"},
            1_000
          )

          assert File.exists?(directory)
          assert Process.alive?(worker)
          send(worker, :release_apply)
          ack = Protocol.ack(event)

          assert_push(
            "task_status",
            %{"task_id" => ^id, "state" => "succeeded", "result" => ^ack},
            5_000
          )

          assert Process.alive?(socket.channel_pid)
          refute File.exists?(directory)
        end
      after
        send(worker, :release_apply)
      end
    end
  end

  defp receive_chunks(socket, chunks) do
    assert_receive %Phoenix.Socket.Message{event: "task_submit", payload: command}, 2_000

    case command["operation"] do
      "blob_chunk" ->
        bytes = Base.decode64!(command["payload"]["data"])
        assert byte_size(bytes) <= 65_536

        assert byte_size(
                 Jason.encode!([socket.join_ref, nil, socket.topic, "task_submit", command])
               ) <= 131_072

        before = state(socket).assigns.sync_manager.last_progress_at
        refute_receive %Phoenix.Socket.Message{event: "task_submit"}, 30

        settle(
          socket,
          command,
          Map.take(command["payload"], ~w(transfer_id blob_id))
          |> Map.put("received_bytes", command["payload"]["offset"] + byte_size(bytes))
        )

        confirmed = state(socket).assigns.sync_manager.last_progress_at
        assert confirmed > before
        assert map_size(state(socket).assigns.round_slots) <= 32
        assert length(state(socket).assigns.queue) <= 32
        receive_chunks(socket, [bytes | chunks])

      "blob_end" ->
        settle(socket, command, %{})
        chunks |> Enum.reverse() |> IO.iodata_to_binary()
    end
  end

  defp equal_item(descriptor),
    do: %{
      "requested" => descriptor,
      "association" => "attached",
      "member" => descriptor,
      "head" => %{
        "version" => descriptor["version"],
        "snapshot_hash" => descriptor["snapshot_hash"],
        "attachments_available" => true
      }
    }

  defp done(socket, sequence, operation, payload) do
    command = command(socket, sequence, operation, payload)
    id = command["task_id"]
    push(socket, "task_submit", command)
    assert_push("task_status", %{"task_id" => ^id, "state" => "queued"}, 2_000)

    assert_push(
      "task_status",
      %{"task_id" => ^id, "state" => "succeeded", "result" => result},
      5_000
    )

    result
  end

  defp command(socket, sequence, operation, payload),
    do: %{
      "task_id" => "#{socket.assigns.session_peer.id}:#{sequence}",
      "operation" => operation,
      "payload" => payload
    }

  defp settle(socket, command, result) do
    push(socket, "task_status", %{
      "task_id" => command["task_id"],
      "status_seq" => 1,
      "state" => "succeeded",
      "phase" => "complete",
      "progress" => %{},
      "result" => result,
      "error" => nil
    })
  end

  defp state(socket), do: :sys.get_state(socket.channel_pid, 1_000)
  defp chunks(<<>>), do: []

  defp chunks(bytes) do
    size = min(byte_size(bytes), 65_536)
    <<chunk::binary-size(size), rest::binary>> = bytes
    [chunk | chunks(rest)]
  end

  defp event(peer, content) do
    stamp = %{"node_id" => peer.id, "millis" => System.system_time(:millisecond), "counter" => 0}

    [key, value] = String.split(hd(peer.selectors), "=", parts: 2)

    snapshot = %{
      "title" => "task",
      "content" => content,
      "labels" => [
        %{"key" => key, "value" => value, "description" => "", "value_type" => "text"}
      ],
      "attachments" => [],
      "created_at" => 1,
      "updated_at" => 1,
      "deleted_at" => nil
    }

    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => Ecto.UUID.generate(),
      "kind" => "attach",
      "generation" => stamp,
      "control" => stamp,
      "version" => stamp,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot),
      "snapshot" => snapshot
    }
  end
end
