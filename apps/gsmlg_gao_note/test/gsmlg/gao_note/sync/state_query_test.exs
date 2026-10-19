defmodule GSMLG.GaoNote.Sync.StateQueryTest do
  use GSMLG.GaoNote.DataCase, async: false
  alias GSMLG.GaoNote.{Compat, Sync}
  alias GSMLG.GaoNote.Sync.{Engine, Protocol, StateQuery, Store}

  defmodule HeadStub do
    import Plug.Conn
    def init(options), do: options

    def call(conn, options) do
      send(options[:owner], {:object_probe, conn.method})
      %{status: status, size: size} = Agent.get(options[:state], & &1)
      conn |> put_resp_header("content-length", Integer.to_string(size)) |> send_resp(status, "")
    end
  end

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()

    {:ok, joined} =
      Sync.join(%{
        "protocol_version" => 1,
        "node_id" => Ecto.UUID.generate(),
        "selectors" => ["project=bear_note"],
        "max_blob_bytes" => 536_870_912
      })

    event =
      GSMLG.GaoNote.SyncFixtures.event()
      |> Map.put("event_id", Ecto.UUID.generate())
      |> Map.put("note_id", Ecto.UUID.generate())

    event = put_in(event, ["snapshot", "attachments"], [])
    event = Map.put(event, "snapshot_hash", Protocol.snapshot_hash(event["snapshot"]))
    %{peer: joined.peer, event: event}
  end

  test "query validates strict bounded descriptors and exact response coverage", %{event: event} do
    descriptor = Protocol.ack(event)
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}
    assert StateQuery.valid_request?(query)
    refute StateQuery.valid_request?(%{query | "items" => []})
    refute StateQuery.valid_request?(Map.put(query, "extra", true))
    refute StateQuery.valid_request?(%{query | "items" => [descriptor, descriptor]})
    refute StateQuery.valid_request?(%{query | "items" => List.duplicate(descriptor, 33)})

    item = %{
      "requested" => descriptor,
      "association" => "missing",
      "member" => nil,
      "head" => nil
    }

    response = %{"query_id" => query["query_id"], "items" => [item]}
    assert StateQuery.valid_response?(query, response)
    refute StateQuery.valid_response?(query, %{response | "items" => []})
    refute StateQuery.valid_response?(query, %{response | "query_id" => Ecto.UUID.generate()})
    refute StateQuery.valid_response?(query, %{response | "items" => [item, item]})

    second = %{descriptor | "note_id" => Ecto.UUID.generate(), "event_id" => Ecto.UUID.generate()}
    query = %{query | "items" => [descriptor, second]}
    response = %{response | "items" => [item, %{item | "requested" => second}]}
    assert StateQuery.valid_response?(query, response)

    refute StateQuery.valid_response?(query, %{
             response
             | "items" => Enum.reverse(response["items"])
           })
  end

  test "read is peer scoped and reports actual head without changing receipts pending or pins", %{
    peer: peer,
    event: event
  } do
    assert {:ok, _} = Sync.apply(peer, event, %{})
    descriptor = Protocol.ack(event)
    current_descriptor = Protocol.ack(Sync.membership(peer.id, event["note_id"])["event"])
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}
    before = Repo.all(GSMLG.GaoNote.Sync.Record)
    pins = Repo.all(GSMLG.GaoNote.Sync.Pin)

    assert {:ok,
            %{
              "items" => [
                %{
                  "requested" => ^descriptor,
                  "association" => "attached",
                  "member" => ^current_descriptor,
                  "head" => head
                }
              ]
            }} = Engine.query_state(peer, query)

    assert head == %{
             "version" => event["version"],
             "snapshot_hash" => event["snapshot_hash"],
             "attachments_available" => true
           }

    assert Repo.all(GSMLG.GaoNote.Sync.Record) == before
    assert Repo.all(GSMLG.GaoNote.Sync.Pin) == pins
    head = Store.get("head", event["note_id"]) |> Map.put("hash", String.duplicate("f", 64))
    Store.put("head", event["note_id"], head, nil, event["note_id"])

    assert {:ok, %{"items" => [%{"head" => %{"snapshot_hash" => hash}}]}} =
             Engine.query_state(peer, query)

    assert hash == head["hash"]
    other = %{peer | id: Ecto.UUID.generate()}
    assert {:error, _} = Engine.query_state(other, query)
  end

  test "accepted Attach retires to a nonpending Snapshot while exact received ACK stays stable",
       %{
         peer: peer,
         event: event
       } do
    for incoming <- [event, Map.put(event, "event_id", Ecto.UUID.generate())] do
      expected = Protocol.ack(incoming)
      assert {:ok, ^expected} = Sync.apply(peer, incoming, %{})
      member = Sync.membership(peer.id, incoming["note_id"])
      assert member["event"]["kind"] == "snapshot"
      refute member["event"]["event_id"] == incoming["event_id"]

      for key <- ~w(note_id generation control version snapshot_hash snapshot),
          do: assert(member["event"][key] == incoming[key])

      assert [] = Sync.pending(peer.id)
      descriptor = Protocol.ack(member["event"])
      query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}
      assert {:ok, %{"items" => [item]}} = Engine.query_state(peer, query)
      assert StateQuery.equal?(descriptor, false, item)
      assert {:ok, ^expected} = Sync.apply(peer, incoming, %{})
      assert Sync.membership(peer.id, incoming["note_id"]) == member
    end
  end

  test "equality only skips nonpending Snapshot with matching membership head and durable objects",
       %{event: event} do
    local = Map.put(Protocol.ack(event), "kind", "snapshot")

    remote = %{
      "requested" => local,
      "association" => "attached",
      "member" => Protocol.ack(event),
      "head" => %{
        "version" => event["version"],
        "snapshot_hash" => event["snapshot_hash"],
        "attachments_available" => true
      }
    }

    assert StateQuery.equal?(local, false, remote)
    refute StateQuery.equal?(local, true, remote)
    refute StateQuery.equal?(Protocol.ack(event), false, remote)

    for available <- [false, nil],
        do:
          refute(
            StateQuery.equal?(
              local,
              false,
              put_in(remote, ["head", "attachments_available"], available)
            )
          )

    refute StateQuery.equal?(local, false, %{remote | "association" => "detached"})

    refute StateQuery.equal?(
             local,
             false,
             put_in(remote, ["head", "snapshot_hash"], String.duplicate("0", 64))
           )
  end

  test "missing membership recovery preserves control clocks and needs exact ACK", %{
    peer: peer,
    event: event
  } do
    assert {:ok, _} = Sync.apply(peer, event, %{})
    assert {:ok, lease} = Sync.checkout(peer, event["note_id"])
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
    member = Sync.membership(peer.id, event["note_id"])
    descriptor = Protocol.ack(member["event"])
    assert descriptor["kind"] == "snapshot"

    missing = %{
      "requested" => descriptor,
      "association" => "missing",
      "member" => nil,
      "head" => nil
    }

    assert {:ok, recovered} = Engine.checkout_compared(peer, descriptor, missing)
    assert recovered.event["kind"] == "attach"
    refute recovered.event["event_id"] == descriptor["event_id"]

    for key <- ~w(generation control version snapshot_hash),
        do: assert(recovered.event[key] == descriptor[key])

    assert [_] = Sync.pending(peer.id)
    assert {:error, :ack_mismatch} = Sync.ack(peer, descriptor, recovered.lease_id)
    assert :ok = Sync.ack(peer, Protocol.ack(recovered.event), recovered.lease_id)
    assert [] = Sync.pending(peer.id)
  end

  test "object availability requires committed references and object stat without downloading bytes",
       %{peer: peer, event: event} do
    {:ok, state} = Agent.start_link(fn -> %{status: 200, size: 4} end)

    server =
      start_supervised!(
        {Bandit, plug: {HeadStub, owner: self(), state: state}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    previous = Application.fetch_env(:gsmlg_storage, :s3_endpoint)
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:gsmlg_storage, :s3_endpoint, value)
        :error -> Application.delete_env(:gsmlg_storage, :s3_endpoint)
      end
    end)

    assert {:ok, _} = Sync.apply(peer, event, %{})

    file =
      GSMLG.Storage.TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
        tenant: "gao_note",
        type: "attachment",
        filename: "a.txt",
        s3_key: Ecto.UUID.generate(),
        content_type: "text/plain",
        size: 4,
        checksum: Protocol.sha256("test")
      })

    attachment = %{
      "id" => "a",
      "path" => "a.txt",
      "mime" => "text/plain",
      "description" => "",
      "size_bytes" => 4,
      "checksum_sha256" => file.checksum
    }

    id = event["note_id"]
    head = Store.get("head", id) |> put_in(["snapshot", "attachments"], [attachment])
    head = Map.put(head, "objects", %{"a" => file.id})
    Store.put("head", id, head, nil, id)
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [Protocol.ack(event)]}

    assert {:ok, %{"items" => [%{"head" => %{"attachments_available" => true}}]}} =
             Engine.query_state(peer, query)

    assert_receive {:object_probe, "HEAD"}
    refute_receive {:object_probe, "GET"}
    Agent.update(state, &%{&1 | status: 404})

    assert {:ok, %{"items" => [%{"head" => %{"attachments_available" => false}}]}} =
             Engine.query_state(peer, query)

    Agent.update(state, &%{&1 | status: 503})

    assert {:ok, %{"items" => [%{"head" => %{"attachments_available" => nil}}]}} =
             Engine.query_state(peer, query)

    Store.put("head", id, %{head | "objects" => %{}}, nil, id)

    assert {:ok, %{"items" => [%{"head" => %{"attachments_available" => false}}]}} =
             Engine.query_state(peer, query)
  end

  test "stale comparisons cannot skip edits and equal pending snapshots still require exact ACK",
       %{peer: peer, event: event} do
    assert {:ok, _} = Sync.apply(peer, event, %{})
    assert {:ok, first} = Sync.checkout(peer, event["note_id"])
    assert :ok = Sync.ack(peer, Protocol.ack(first.event), first.lease_id)
    descriptor = Protocol.ack(Sync.membership(peer.id, event["note_id"])["event"])

    equal = %{
      "requested" => descriptor,
      "association" => "attached",
      "member" => descriptor,
      "head" => %{
        "version" => descriptor["version"],
        "snapshot_hash" => descriptor["snapshot_hash"],
        "attachments_available" => true
      }
    }

    assert :equal = Engine.checkout_compared(peer, descriptor, equal)
    assert [] = Store.list("lease", peer.id)
    note = Repo.get!(GSMLG.GaoNote.Note, event["note_id"])

    assert {:ok, _} =
             Compat.patch_note(note.id, note.revision, %{content: "new local content"}, nil)

    assert :superseded = Engine.checkout_compared(peer, descriptor, equal)
    [pending] = Sync.pending(peer.id)
    pending_descriptor = Protocol.ack(pending)

    remote = %{
      equal
      | "requested" => pending_descriptor,
        "member" => pending_descriptor,
        "head" => %{
          "version" => pending["version"],
          "snapshot_hash" => pending["snapshot_hash"],
          "attachments_available" => true
        }
    }

    assert {:ok, lease} = Engine.checkout_compared(peer, pending_descriptor, remote)
    assert lease.event == pending
    assert [_] = Sync.pending(peer.id)
    assert :ok = Sync.ack(peer, pending_descriptor, lease.lease_id)
    assert [] = Sync.pending(peer.id)
  end

  test "inventory classifies authorized blocked notes without failing the whole round", %{
    peer: peer
  } do
    {:ok, selected} =
      Compat.save_note(
        %{title: "selected", content: "body", labels: [["project", "bear_note"]]},
        nil
      )

    {:ok, _other} = Compat.save_note(%{title: "not selected", content: "body", labels: []}, nil)

    Repo.insert!(%GSMLG.GaoNote.Attachment{
      id: Ecto.UUID.generate(),
      api_id: Ecto.UUID.generate(),
      note_id: selected.id,
      storage_file_id: Ecto.UUID.generate(),
      path: "./missing.txt",
      mime: "text/plain"
    })

    Store.delete("member", selected.id, peer.id)
    Store.delete("pending", selected.id, peer.id)
    assert {:ok, [%{note_id: id, unclassified: true}]} = Engine.inventory_plan(peer)
    assert id == selected.id
    assert {:ok, %{note_id: ^id, blocked: true}} = Engine.classify_inventory_note(peer, id)
  end

  test "a matching pending Snapshot recovers missing membership with a fresh Attach", %{
    peer: peer,
    event: event
  } do
    assert {:ok, _} = Sync.apply(peer, event, %{})
    assert {:ok, first} = Sync.checkout(peer, event["note_id"])
    assert :ok = Sync.ack(peer, Protocol.ack(first.event), first.lease_id)
    note = Repo.get!(GSMLG.GaoNote.Note, event["note_id"])
    assert {:ok, _} = Compat.patch_note(note.id, note.revision, %{content: "pending change"}, nil)
    [snapshot] = Sync.pending(peer.id)
    assert snapshot["kind"] == "snapshot"
    descriptor = Protocol.ack(snapshot)

    missing = %{
      "requested" => descriptor,
      "association" => "missing",
      "member" => nil,
      "head" => nil
    }

    assert {:ok, recovered} = Engine.checkout_compared(peer, descriptor, missing)
    assert recovered.event["kind"] == "attach"

    for key <- ~w(note_id generation control version snapshot_hash),
        do: assert(recovered.event[key] == snapshot[key])

    refute recovered.event["event_id"] == snapshot["event_id"]
    assert [pending] = Sync.pending(peer.id)
    assert pending == recovered.event
    assert :ok = Sync.ack(peer, Protocol.ack(pending), recovered.lease_id)
    assert [] = Sync.pending(peer.id)
  end

  test "detached memberships never disclose later private head state", %{peer: peer, event: event} do
    assert {:ok, _} = Sync.apply(peer, event, %{})

    detached =
      event
      |> Map.merge(%{
        "event_id" => Ecto.UUID.generate(),
        "kind" => "detach",
        "control" => %{event["control"] | "millis" => event["control"]["millis"] + 1}
      })

    assert {:ok, _} = Sync.apply(peer, detached, %{})
    note = Repo.get!(GSMLG.GaoNote.Note, event["note_id"])

    assert {:ok, _} =
             Compat.patch_note(note.id, note.revision, %{content: "private after detach"}, nil)

    descriptor = Protocol.ack(event)
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}

    assert {:ok,
            %{"items" => [%{"association" => "detached", "member" => member, "head" => nil}]}} =
             Engine.query_state(peer, query)

    assert member["snapshot_hash"] == event["snapshot_hash"]
    Store.delete("member", note.id, peer.id)

    assert {:ok, %{"items" => [%{"association" => "missing", "head" => nil}]}} =
             Engine.query_state(peer, query)
  end

  test "association validation rejects detached heads and membership hash conflicts", %{
    peer: peer,
    event: event
  } do
    assert {:ok, _} = Sync.apply(peer, event, %{})
    {:ok, first} = Sync.checkout(peer, event["note_id"])
    :ok = Sync.ack(peer, Protocol.ack(first.event), first.lease_id)
    descriptor = Protocol.ack(Sync.membership(peer.id, event["note_id"])["event"])
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}

    head = %{
      "version" => descriptor["version"],
      "snapshot_hash" => descriptor["snapshot_hash"],
      "attachments_available" => true
    }

    item = %{
      "requested" => descriptor,
      "association" => "detached",
      "member" => descriptor,
      "head" => head
    }

    refute StateQuery.valid_response?(query, %{"query_id" => query["query_id"], "items" => [item]})

    conflict = %{
      item
      | "association" => "attached",
        "member" => Map.put(descriptor, "snapshot_hash", String.duplicate("0", 64)),
        "head" => nil
    }

    refute StateQuery.valid_response?(query, %{
             "query_id" => query["query_id"],
             "items" => [conflict]
           })

    assert {:error, :version_conflict} = Engine.checkout_compared(peer, descriptor, conflict)

    newer = %{descriptor["version"] | "millis" => descriptor["version"]["millis"] + 1}

    conflict = %{
      conflict
      | "member" => Map.put(descriptor, "version", newer),
        "head" => %{head | "version" => newer, "snapshot_hash" => String.duplicate("0", 64)}
    }

    refute StateQuery.valid_response?(query, %{
             "query_id" => query["query_id"],
             "items" => [conflict]
           })

    assert {:error, :version_conflict} = Engine.checkout_compared(peer, descriptor, conflict)
  end
end
