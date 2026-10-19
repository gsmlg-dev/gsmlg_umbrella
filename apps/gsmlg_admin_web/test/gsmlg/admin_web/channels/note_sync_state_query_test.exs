defmodule GSMLG.AdminWeb.NoteSyncStateQueryTest do
  use GSMLG.AdminWeb.ChannelCase, async: false
  alias GSMLG.AdminWeb.{NoteSyncChannel, NoteSyncSocket}
  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Store}

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    {:ok, connected} = connect(NoteSyncSocket, %{})

    payload = %{
      "protocol_version" => 1,
      "node_id" => Ecto.UUID.generate(),
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }

    {:ok, response, socket} =
      subscribe_and_join(connected, NoteSyncChannel, "note_sync:v1", payload)

    Process.unlink(socket.channel_pid)

    on_exit(fn ->
      guard = Process.monitor(socket.assigns.guard)
      if Process.alive?(socket.channel_pid), do: Process.exit(socket.channel_pid, :shutdown)
      assert_receive {:DOWN, ^guard, :process, _, _}, 5000
    end)

    %{socket: socket, response: response, peer: socket.assigns.session_peer}
  end

  test "capability negotiation cannot originate queries before inventory start", %{
    socket: socket,
    response: response
  } do
    assert response["capabilities"] == ["state_query_v1"]
    ref = push(socket, "sync_negotiate", %{"capabilities" => ["state_query_v1"]})
    assert_reply(ref, :ok, %{"capabilities" => ["state_query_v1"]})
    refute_receive %Phoenix.Socket.Message{event: "state_query"}, 50
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)
    assert_push("inventory_complete", %{"inventory_id" => round, "total_notes" => 0})
    assert Protocol.uuid?(round)
    monitor = Process.monitor(socket.channel_pid)
    push(socket, "sync_negotiate", %{"capabilities" => []})
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 2000
  end

  test "inbound probe remains responsive while reciprocal query waits and equal audit emits no blobs",
       %{socket: socket, peer: peer} do
    {:ok, note} =
      Compat.save_note(%{title: "same", content: "same", labels: [["project", "bear_note"]]}, nil)

    {:ok, lease} = Sync.checkout(peer, note.id)
    :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    ref = push(socket, "sync_negotiate", %{"capabilities" => ["state_query_v1"]})
    assert_reply(ref, :ok, %{"capabilities" => ["state_query_v1"]})
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)

    assert_receive %Phoenix.Socket.Message{event: "state_query", ref: query_ref, payload: query},
                   2000

    assert [descriptor] = query["items"]
    assert descriptor["kind"] == "snapshot"
    probe = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}
    ref = push(socket, "state_query", probe)
    assert_reply(ref, :ok, %{"query_id" => _, "items" => [item]}, 2000)
    assert item["head"]["attachments_available"]

    response = %{
      "query_id" => query["query_id"],
      "items" => [%{item | "requested" => descriptor}]
    }

    send(socket.channel_pid, %Phoenix.Socket.Message{
      topic: socket.topic,
      event: "phx_reply",
      ref: query_ref,
      join_ref: socket.join_ref,
      payload: %{"status" => "ok", "response" => response}
    })

    assert_push("inventory_complete", %{"inventory_id" => _, "total_notes" => 1})
    refute_receive %Phoenix.Socket.Message{event: "transfer_begin"}, 50
    assert [] = Sync.pending(peer.id)
    assert [] = Store.list("lease", peer.id)
  end

  test "legacy start and completion retain empty payloads", %{socket: socket} do
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)
    assert_push("inventory_complete", %{})
    ref = push(socket, "inventory_complete", %{})
    assert_reply(ref, :ok, %{})
  end

  for invalid <- [
        %{"capabilities" => ["state_query_v1", "state_query_v1"]},
        %{"capabilities" => ["unknown"]},
        %{"capabilities" => ["state_query_v1"], "extra" => true},
        %{"capabilities" => "state_query_v1"}
      ] do
    @tag invalid_negotiation: invalid
    test "negotiation rejects #{inspect(invalid)}", %{
      socket: socket,
      invalid_negotiation: payload
    } do
      monitor = Process.monitor(socket.channel_pid)
      push(socket, "sync_negotiate", payload)
      assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 2000
    end
  end

  test "pending notes require exact durable ACK despite equal probe and audit gets bounded service",
       %{socket: socket, peer: peer} do
    notes =
      for n <- 1..10 do
        {:ok, note} =
          Compat.save_note(
            %{title: "note #{n}", content: "body", labels: [["project", "bear_note"]]},
            nil
          )

        note
      end

    [audit | _] = Enum.sort_by(notes, & &1.id)
    {:ok, lease} = Sync.checkout(peer, audit.id)
    :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    negotiate_and_start(socket)

    ids =
      for _ <- 1..10 do
        assert_receive %Phoenix.Socket.Message{event: "state_query", ref: ref, payload: query},
                       2000

        [descriptor] = query["items"]

        item = %{
          "requested" => descriptor,
          "association" => "attached",
          "member" => descriptor,
          "head" => %{
            "version" => descriptor["version"],
            "snapshot_hash" => descriptor["snapshot_hash"],
            "attachments_available" => true
          }
        }

        wire_reply(socket, ref, %{"query_id" => query["query_id"], "items" => [item]})

        if descriptor["note_id"] != audit.id do
          sent = finish_note(socket)
          assert Protocol.ack(sent) == descriptor
        end

        descriptor["note_id"]
      end

    assert Enum.at(ids, 8) == audit.id
    refute audit.id in Enum.take(ids, 8)
    assert Enum.sort(ids) == Enum.sort(Enum.map(notes, & &1.id))
    assert_push("inventory_complete", %{"inventory_id" => _, "total_notes" => 10}, 2000)
    assert [] = Sync.pending(peer.id)
  end

  test "asynchronous query response bounds include the original request reference", %{
    socket: socket,
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(
        %{title: "bounds", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    descriptor = Protocol.ack(Sync.membership(peer.id, note.id)["event"])
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}
    ref = push(socket, "sync_negotiate", %{"capabilities" => ["state_query_v1"]})
    assert_reply(ref, :ok, %{"capabilities" => ["state_query_v1"]})
    overhead = byte_size(Jason.encode!([socket.join_ref, "", socket.topic, "state_query", query]))
    large_ref = String.duplicate("r", 131_072 - overhead)
    monitor = Process.monitor(socket.channel_pid)

    send(socket.channel_pid, %Phoenix.Socket.Message{
      topic: socket.topic,
      event: "state_query",
      ref: large_ref,
      join_ref: socket.join_ref,
      payload: query
    })

    send(socket.channel_pid, %Phoenix.Socket.Message{
      topic: socket.topic,
      event: "inventory_complete",
      ref: "short",
      join_ref: socket.join_ref,
      payload: %{"inventory_id" => Ecto.UUID.generate(), "total_notes" => 0}
    })

    assert_reply("short", :ok, %{})

    receive do
      {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}} -> :ok
      %Phoenix.Socket.Reply{ref: ^large_ref} -> flunk("oversized query response was sent")
    after
      2000 -> flunk("oversized query response did not end the session")
    end
  end

  test "malformed capable query reply terminates rather than falling back to replay", %{
    socket: socket
  } do
    {:ok, _note} =
      Compat.save_note(
        %{title: "pending", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    negotiate_and_start(socket)
    assert_receive %Phoenix.Socket.Message{event: "state_query", ref: ref, payload: query}, 2000
    monitor = Process.monitor(socket.channel_pid)
    wire_reply(socket, ref, %{"query_id" => query["query_id"], "items" => []})
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 2000
    refute_receive %Phoenix.Socket.Message{event: "transfer_begin"}, 50
  end

  test "legacy pending work advances ahead of lower UUID acknowledged inventory", %{
    socket: socket,
    peer: peer
  } do
    notes =
      for n <- 1..3 do
        {:ok, note} =
          Compat.save_note(
            %{title: "note #{n}", content: "body", labels: [["project", "bear_note"]]},
            nil
          )

        note
      end

    [low, middle, high] = Enum.sort_by(notes, & &1.id)

    for note <- [low, middle] do
      {:ok, lease} = Sync.checkout(peer, note.id)
      :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    end

    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)
    sent = finish_note(socket)
    assert sent["note_id"] == high.id
  end

  test "negotiated completion counts eligible UUIDs and rejects legacy empty completion", %{
    socket: socket,
    peer: peer
  } do
    {:ok, note} =
      Compat.save_note(
        %{title: "selected", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, _} = Compat.save_note(%{title: "unselected", content: "body", labels: []}, nil)
    {:ok, lease} = Sync.checkout(peer, note.id)
    :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    negotiate_and_start(socket)
    assert_receive %Phoenix.Socket.Message{event: "state_query", ref: ref, payload: query}, 2000
    [descriptor] = query["items"]

    item = %{
      "requested" => descriptor,
      "association" => "attached",
      "member" => descriptor,
      "head" => %{
        "version" => descriptor["version"],
        "snapshot_hash" => descriptor["snapshot_hash"],
        "attachments_available" => true
      }
    }

    wire_reply(socket, ref, %{"query_id" => query["query_id"], "items" => [item]})
    assert_push("inventory_complete", %{"inventory_id" => round_id, "total_notes" => 1}, 2000)
    ref = push(socket, "inventory_complete", %{"inventory_id" => round_id, "total_notes" => 1})
    assert_reply(ref, :ok, %{})
    monitor = Process.monitor(socket.channel_pid)
    push(socket, "inventory_complete", %{})
    assert_receive {:DOWN, ^monitor, :process, _, {:shutdown, :sync_session_error}}, 2000
  end

  test "a locally unpreparable captured note yields to the next note without losing pending", %{
    socket: socket,
    peer: peer
  } do
    notes =
      for n <- 1..2 do
        {:ok, note} =
          Compat.save_note(
            %{title: "note #{n}", content: "body", labels: [["project", "bear_note"]]},
            nil
          )

        note
      end

    [broken, healthy] = Enum.sort_by(notes, & &1.id)

    GSMLG.Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: Ecto.UUID.generate(),
      note_id: broken.id,
      storage_file_id: Ecto.UUID.generate(),
      path: "./missing.txt",
      mime: "text/plain"
    })

    negotiate_and_start(socket)

    for expected <- [broken.id, healthy.id] do
      assert_receive %Phoenix.Socket.Message{event: "state_query", ref: ref, payload: query}, 2000
      [descriptor] = query["items"]
      assert descriptor["note_id"] == expected

      item = %{
        "requested" => descriptor,
        "association" => "missing",
        "member" => nil,
        "head" => nil
      }

      wire_reply(socket, ref, %{"query_id" => query["query_id"], "items" => [item]})
    end

    assert finish_note(socket)["note_id"] == healthy.id
    assert_push("inventory_complete", %{"inventory_id" => _, "total_notes" => 2}, 2000)
    assert [pending] = Sync.pending(peer.id)
    assert pending["note_id"] == broken.id
    assert [] = Store.list("lease", peer.id)
    assert Process.alive?(socket.channel_pid)
  end

  test "new inventory rounds replace the idle audit timer", %{socket: socket} do
    negotiate_and_start(socket)
    assert_push("inventory_complete", %{"inventory_id" => first, "total_notes" => 0})
    old_timer = :sys.get_state(socket.channel_pid).assigns.reconcile_timer
    assert Process.read_timer(old_timer) > 0
    send(socket.channel_pid, :reconcile_inventory)
    assert_push("inventory_complete", %{"inventory_id" => second, "total_notes" => 0}, 2000)
    refute first == second
    assert Process.read_timer(old_timer) == false
    assert Process.read_timer(:sys.get_state(socket.channel_pid).assigns.reconcile_timer) > 0
  end

  defp negotiate_and_start(socket) do
    ref = push(socket, "sync_negotiate", %{"capabilities" => ["state_query_v1"]})
    assert_reply(ref, :ok, %{"capabilities" => ["state_query_v1"]})
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2000)
  end

  defp wire_reply(socket, ref, response) do
    send(socket.channel_pid, %Phoenix.Socket.Message{
      topic: socket.topic,
      event: "phx_reply",
      ref: ref,
      join_ref: socket.join_ref,
      payload: %{"status" => "ok", "response" => response}
    })
  end

  defp finish_note(socket) do
    assert_receive %Phoenix.Socket.Message{event: "transfer_begin", ref: ref, payload: manifest},
                   2000

    wire_reply(socket, ref, %{})
    event = collect_event(socket, []) |> Jason.decode!()

    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: ref, payload: commit},
                   2000

    assert commit["transfer_id"] == manifest["transfer_id"]
    wire_reply(socket, ref, Protocol.ack(event))
    event
  end

  defp collect_event(socket, chunks) do
    receive do
      %Phoenix.Socket.Message{event: "blob_chunk", payload: payload} ->
        collect_event(socket, [Base.decode64!(payload["data"]) | chunks])

      %Phoenix.Socket.Message{event: "blob_end", ref: ref} ->
        wire_reply(socket, ref, %{})
        chunks |> Enum.reverse() |> IO.iodata_to_binary()
    after
      2000 -> flunk("expected metadata chunks followed by blob_end")
    end
  end
end
