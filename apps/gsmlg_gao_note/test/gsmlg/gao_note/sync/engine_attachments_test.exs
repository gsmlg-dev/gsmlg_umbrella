defmodule GSMLG.GaoNote.Sync.EngineAttachmentsTest do
  use GSMLG.GaoNote.DataCase, async: false

  setup do
    GSMLG.Storage.TestCatalogClient.setup!()
    :ok
  end

  alias GSMLG.GaoNote.{Attachment, Attachments, Compat, Note, Sync}
  alias GSMLG.GaoNote.Sync.{Protocol, Snapshot, Store}

  defmodule ObjectStore do
    import Plug.Conn
    def init(table), do: table

    def call(%{method: "PUT"} = conn, table) do
      {:ok, bytes, conn} = read_body(conn)
      :ets.insert(table, {conn.request_path, bytes})
      send_resp(conn, 200, "")
    end

    def call(%{method: "DELETE"} = conn, table) do
      :ets.delete(table, conn.request_path)
      send_resp(conn, 204, "")
    end

    def call(%{method: "GET"} = conn, table) do
      case :ets.lookup(table, conn.request_path) do
        [{_, bytes}] ->
          case get_req_header(conn, "range") do
            [range] when bytes != "" ->
              [_, first, last] = Regex.run(~r/^bytes=(\d+)-(\d+)$/, range)
              first = String.to_integer(first)
              last = min(String.to_integer(last), byte_size(bytes) - 1)
              send_resp(conn, 206, binary_part(bytes, first, last - first + 1))

            _ ->
              send_resp(conn, 200, bytes)
          end

        [] ->
          send_resp(conn, 404, "")
      end
    end
  end

  setup do
    table = :ets.new(:sync_objects, [:set, :public])
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    start_supervised!({Bandit, plug: {ObjectStore, table}, port: port, startup_log: false})

    config = %{
      allowed_types: %{"gao_note_attachment" => :any},
      s3_access_key_id: "test",
      s3_secret_access_key: "test",
      s3_endpoint: "http://127.0.0.1:#{port}",
      s3_bucket: "sync-test"
    }

    previous =
      Map.new(config, fn {key, _} -> {key, Application.fetch_env(:gsmlg_storage, key)} end)

    Enum.each(config, fn {key, value} -> Application.put_env(:gsmlg_storage, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    {:ok, registered} =
      Sync.register_peer(%{
        node_id: Ecto.UUID.generate(),
        certificate_fingerprint: String.duplicate("e", 64),
        actor_id: "attachment-peer",
        allowed_selectors: ["project=bear_note"]
      })

    {:ok, joined} = Sync.join(registered, payload(registered))
    %{peer: joined.peer, objects: table}
  end

  test "inbound complete sets preserve public IDs through path swaps and outbound reads", %{
    peer: peer
  } do
    id = Ecto.UUID.generate()
    first = event(peer, id, 1000, [{"event", "one.txt", "one"}, {"second", "two.txt", "two"}])
    assert {:ok, _} = Sync.apply(peer, first, %{"event" => "one", "second" => "two"})

    original_ids =
      Repo.all(from(a in Attachment, where: a.note_id == ^id, select: {a.api_id, a.id}))
      |> Map.new()

    swapped =
      event(peer, id, 2000, [{"second", "one.txt", "two replaced"}, {"event", "two.txt", "one"}])
      |> Map.put("kind", "snapshot")

    assert {:ok, _} = Sync.apply(peer, swapped, %{"event" => "one", "second" => "two replaced"})
    assert {:ok, built} = Snapshot.build(id)
    assert built.snapshot == swapped["snapshot"]

    assert Repo.all(from(a in Attachment, where: a.note_id == ^id, select: {a.api_id, a.id}))
           |> Map.new() == original_ids

    assert {:ok, lease} = Sync.checkout(peer, id)
    assert lease.event["snapshot"] == swapped["snapshot"]
    assert {:ok, "one"} = Snapshot.read_object(lease.objects["event"])
    assert {:ok, "two replaced"} = Snapshot.read_object(lease.objects["second"])
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)

    removed = event(peer, id, 3000, [{"event", "two.txt", "one"}]) |> Map.put("kind", "snapshot")
    assert {:ok, _} = Sync.apply(peer, removed, %{"event" => "one"})

    assert [%Attachment{api_id: "event"} = attachment] =
             Repo.all(from(a in Attachment, where: a.note_id == ^id))

    assert {:ok, _, "one"} = Attachments.get_with_content(id, attachment.id)
  end

  test "zero-byte binary MIME survives inbound apply and outbound reads", %{peer: peer} do
    id = Ecto.UUID.generate()
    incoming = event(peer, id, 1000, [{"empty", "assets/empty.bin", ""}])

    incoming =
      put_in(
        incoming,
        ["snapshot", "attachments", Access.at(0), "mime"],
        "application/octet-stream"
      )

    incoming = Map.put(incoming, "snapshot_hash", Protocol.snapshot_hash(incoming["snapshot"]))

    assert {:ok, _} = Sync.apply(peer, incoming, %{"empty" => ""})
    assert {:ok, built} = Snapshot.build(id)
    assert built.snapshot == incoming["snapshot"]
    assert {:ok, lease} = Sync.checkout(peer, id)
    assert {:ok, ""} = Snapshot.read_object(lease.objects["empty"])
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
  end

  test "path extension changes preserve wire MIME and the complete snapshot", %{peer: peer} do
    id = Ecto.UUID.generate()
    first = event(peer, id, 1000, [{"renamed", "assets/file.txt", "plain text"}])
    assert {:ok, _} = Sync.apply(peer, first, %{"renamed" => "plain text"})

    renamed =
      event(peer, id, 2000, [{"renamed", "assets/file.md", "plain text"}])
      |> Map.put("kind", "snapshot")

    assert {:ok, _} = Sync.apply(peer, renamed, %{"renamed" => "plain text"})
    assert {:ok, built} = Snapshot.build(id)
    assert built.snapshot == renamed["snapshot"]
    assert {:ok, lease} = Sync.checkout(peer, id)
    assert {:ok, "plain text"} = Snapshot.read_object(lease.objects["renamed"])
    assert :ok = Sync.ack(peer, Protocol.ack(lease.event), lease.lease_id)
  end

  test "wire MIME cannot disguise detected content excluded by storage policy", %{peer: peer} do
    Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => ["text/plain"]})

    incoming =
      event(peer, Ecto.UUID.generate(), 1000, [
        {"disguised", "assets/file.txt", "<html>active</html>"}
      ])

    assert {:error, {:note_rejected, "validation_failed"}} =
             Sync.apply(peer, incoming, %{"disguised" => "<html>active</html>"})

    refute Repo.get(Note, incoming["note_id"])
    refute GSMLG.Storage.TestCatalogClient.files(status: "active") != []
  end

  test "catalog rejection rolls back content and discards staged objects", %{
    peer: peer,
    objects: objects
  } do
    {:ok, _} = Compat.define_label_key("project", %{description: "local catalog"})

    {:ok, local} =
      Compat.save_note(
        %{
          title: "local",
          content: "body",
          labels: [["project", "bear_note"]],
          attachments: [%{id: "kept", path: "kept.txt", mime: "text/plain", content: "kept"}]
        },
        nil
      )

    [pending] = Sync.pending(peer.id)
    files = Enum.map(GSMLG.Storage.TestCatalogClient.files(status: "active"), & &1.id)
    stored_objects = :ets.tab2list(objects)

    incoming =
      event(peer, local.id, pending["version"]["millis"] + 1, [
        {"replacement", "replacement.txt", "rejected"}
      ])
      |> Map.merge(%{
        "kind" => "snapshot",
        "generation" => pending["generation"],
        "control" => pending["control"]
      })

    assert {:error, {:note_rejected, "catalog_conflict"}} =
             Sync.apply(peer, incoming, %{"replacement" => "rejected"})

    assert %Note{title: "local", revision: 1} = Repo.get!(Note, local.id)
    assert Enum.map(GSMLG.Storage.TestCatalogClient.files(status: "active"), & &1.id) == files
    assert :ets.tab2list(objects) == stored_objects
    assert Store.get("received", incoming["event_id"], peer.id) == nil
    assert [^pending] = Sync.pending(peer.id)
  end

  test "an obsolete session cleans prepared attachments without writing a note", %{
    peer: peer,
    objects: objects
  } do
    {:ok, _} = Sync.join(peer, payload(peer))
    incoming = event(peer, Ecto.UUID.generate(), 1000, [{"stale", "stale.txt", "stale"}])
    assert {:error, :obsolete_session} = Sync.apply(peer, incoming, %{"stale" => "stale"})
    refute Repo.get(Note, incoming["note_id"])
    refute GSMLG.Storage.TestCatalogClient.files(status: "active") != []
    assert :ets.tab2list(objects) == []
  end

  test "declared MIME metadata preserves the hash while storage retains detected MIME", %{
    peer: peer
  } do
    incoming = event(peer, Ecto.UUID.generate(), 1000, [{"bad", "bad.txt", "text"}])
    [attachment] = incoming["snapshot"]["attachments"]

    snapshot =
      Map.put(incoming["snapshot"], "attachments", [Map.put(attachment, "mime", "image/png")])

    incoming =
      Map.merge(incoming, %{
        "snapshot" => snapshot,
        "snapshot_hash" => Protocol.snapshot_hash(snapshot)
      })

    assert {:ok, _} = Sync.apply(peer, incoming, %{"bad" => "text"})
    assert {:ok, built} = Snapshot.build(incoming["note_id"])
    assert built.snapshot == snapshot
    stored = Repo.get_by!(Attachment, note_id: incoming["note_id"], api_id: "bad")

    assert GSMLG.Storage.TestCatalogClient.get_file!(stored.storage_file_id).content_type ==
             "text/plain"
  end

  test "attachment metadata cannot be normalized while recording the remote hash", %{peer: peer} do
    incoming = event(peer, Ecto.UUID.generate(), 1000, [{"mime", "mime.txt", "text"}])
    [attachment] = incoming["snapshot"]["attachments"]

    snapshot =
      Map.put(incoming["snapshot"], "attachments", [Map.put(attachment, "mime", " text/plain ")])

    incoming =
      Map.merge(incoming, %{
        "snapshot" => snapshot,
        "snapshot_hash" => Protocol.snapshot_hash(snapshot)
      })

    assert {:error, {:note_rejected, "validation_failed"}} =
             Sync.apply(peer, incoming, %{"mime" => "text"})

    refute Repo.get(Note, incoming["note_id"])
    assert Store.get("received", incoming["event_id"], peer.id) == nil
  end

  test "native storage MIME and size policies reject only the affected note", %{peer: peer} do
    incoming = event(peer, Ecto.UUID.generate(), 1000, [{"policy", "policy.txt", "text"}])
    previous = Application.get_env(:gsmlg_storage, :max_file_size)

    try do
      Application.put_env(:gsmlg_storage, :allowed_types, %{
        "gao_note_attachment" => ["image/png"]
      })

      assert {:error, {:note_rejected, "validation_failed"}} =
               Sync.apply(peer, incoming, %{"policy" => "text"})

      Application.put_env(:gsmlg_storage, :allowed_types, %{"gao_note_attachment" => :any})
      Application.put_env(:gsmlg_storage, :max_file_size, 1)

      assert {:error, {:note_rejected, "validation_failed"}} =
               Sync.apply(peer, incoming, %{"policy" => "text"})

      refute Repo.get(Note, incoming["note_id"])
      refute GSMLG.Storage.TestCatalogClient.files(status: "active") != []
    after
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_storage, :max_file_size),
        else: Application.put_env(:gsmlg_storage, :max_file_size, previous)
    end
  end

  defp payload(peer),
    do: %{
      "protocol_version" => 1,
      "node_id" => peer.id,
      "selectors" => ["project=bear_note"],
      "max_blob_bytes" => 536_870_912
    }

  defp event(peer, id, millis, files) do
    attachments =
      Enum.map(files, fn {public_id, path, bytes} ->
        %{
          "id" => public_id,
          "path" => path,
          "mime" => "text/plain",
          "description" => "",
          "size_bytes" => byte_size(bytes),
          "checksum_sha256" => Protocol.sha256(bytes)
        }
      end)

    snapshot = %{
      "title" => "remote",
      "content" => "body",
      "created_at" => 1,
      "updated_at" => 1,
      "deleted_at" => nil,
      "labels" => [
        %{"key" => "project", "value" => "bear_note", "description" => "", "value_type" => "text"}
      ],
      "attachments" => attachments
    }

    generation = %{"millis" => 500, "counter" => 0, "node_id" => peer.id}

    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => id,
      "generation" => generation,
      "control" => generation,
      "version" => %{"millis" => millis, "counter" => 0, "node_id" => peer.id},
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot)
    }
  end
end
