defmodule GSMLG.AdminWeb.NoteSyncConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ChannelTest
  alias GSMLG.AdminWeb.{NoteSyncChannel, NoteSyncSocket}
  alias GSMLG.GaoNote.{Compat, Label, LabelSetting, Log, Note}
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Record, Store}
  alias GSMLG.Repo

  @endpoint GSMLG.AdminWeb.Endpoint

  setup do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    previous = Application.fetch_env(:gsmlg_gao_note, :compat_services)
    Application.put_env(:gsmlg_gao_note, :compat_services, [])

    on_exit(fn ->
      case previous do
        {:ok, config} -> Application.put_env(:gsmlg_gao_note, :compat_services, config)
        :error -> Application.delete_env(:gsmlg_gao_note, :compat_services)
      end

      Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual)
    end)

    label = "sync_concurrency_" <> String.replace(Ecto.UUID.generate(), "-", "")
    peer_id = Ecto.UUID.generate()
    remote_id = Ecto.UUID.generate()
    {:ok, connected} = connect(NoteSyncSocket, %{})

    {:ok, _, socket} =
      subscribe_and_join(connected, NoteSyncChannel, "note_sync:v1", %{
        "protocol_version" => 1,
        "node_id" => peer_id,
        "selectors" => [label <> "=selected"],
        "max_blob_bytes" => 536_870_912
      })

    Process.unlink(socket.channel_pid)

    on_exit(fn ->
      close_channel(socket)
      settings = Repo.all(from(s in LabelSetting, where: s.name == ^label, select: s.id))

      ids = [
        remote_id
        | Repo.all(from(l in Label, where: l.label_setting_id in ^settings, select: l.note_id))
      ]

      Repo.delete_all(from(j in Oban.Job, where: fragment("?->>'note_id'", j.args) in ^ids))
      Repo.delete_all(from(l in Log, where: l.note_id in ^ids or l.entity_id in ^settings))
      Repo.delete_all(from(r in Record, where: r.peer_id == ^peer_id or r.note_id in ^ids))
      Repo.delete_all(from(n in Note, where: n.id in ^ids))
      Repo.delete_all(from(s in LabelSetting, where: s.name == ^label))
      Repo.delete_all(from(p in Peer, where: p.id == ^peer_id))
    end)

    {:ok, note} =
      Oban.Testing.with_testing_mode(:manual, fn ->
        Compat.save_note(%{title: "duplex", content: "local", labels: [[label, "selected"]]}, nil)
      end)

    %{
      socket: socket,
      peer: socket.assigns.session_peer,
      note: note,
      remote: remote_event(socket.assigns.session_peer, remote_id, label)
    }
  end

  test "duplex confirmation and pending renewal survive an apply holding the peer lock beyond ten seconds",
       %{socket: socket, peer: peer, remote: remote} do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {outgoing, commit_ref} = outgoing_commit(socket)
      transfer = stage(socket, remote)
      install_apply_barrier(remote["event_id"])
      incoming_ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
      assert_receive {:apply_peer_locked, worker}, 2_000
      on_exit(fn -> send(worker, :release_apply) end)

      try do
        lease_id = state(socket).assigns.outgoing.lease
        lease = Store.get("lease", lease_id, peer.id)
        shortened = System.system_time(:millisecond) + 5_000

        Store.put(
          "lease",
          lease_id,
          Map.put(lease, "expires_at", shortened),
          peer.id,
          outgoing["note_id"]
        )

        reply(socket, commit_ref, Protocol.ack(outgoing))

        confirmation =
          await_state(socket, &(not is_nil(&1.assigns.confirmation_task))).assigns.confirmation_task

        assert Process.read_timer(confirmation.timer) in 1..10_000
        assert_heartbeat(socket)

        await_state(socket, fn _ ->
          Store.get("lease", lease_id, peer.id)["expires_at"] > shortened + 30_000
        end)

        first = Store.get("lease", lease_id, peer.id)["expires_at"]

        Process.sleep(16_100)
        assert_heartbeat(socket)
        assert Process.alive?(worker)
        deferred = state(socket).assigns.confirmation_task
        assert deferred.ref == confirmation.ref
        assert deferred.timer != confirmation.timer
        assert deferred.session_deadline_deferred
        assert Process.read_timer(confirmation.timer) == false
        assert Process.read_timer(deferred.timer) > 10_000
        assert Store.get("lease", lease_id, peer.id)["expires_at"] > first + 8_000
        assert Store.get("ack", lease_id, peer.id) == nil

        send(worker, :release_apply)
        ack = Protocol.ack(remote)
        assert_reply(incoming_ref, :ok, ^ack, 5_000)
        assert_push("ack", ^ack, 5_000)
        await_state(socket, &is_nil(&1.assigns.outgoing))
        assert Store.get("ack", lease_id, peer.id) == Protocol.ack(outgoing)
        assert Repo.get!(Note, remote["note_id"]).content == "remote"
        assert_heartbeat(socket)
      after
        send(worker, :release_apply)
      end
    end)
  end

  test "an existing confirmation defers its deadline once and ignores a superseded expiry", %{
    socket: socket,
    peer: peer,
    remote: remote
  } do
    Oban.Testing.with_testing_mode(:manual, fn ->
      {outgoing, commit_ref} = outgoing_commit(socket)
      lease_id = state(socket).assigns.outgoing.lease
      owner = self()

      blocker =
        Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
          Repo.transaction(
            fn ->
              key = Store.key("lease", peer.id, lease_id)
              Repo.one!(from(r in Record, where: r.id == ^key, lock: "FOR UPDATE"))
              send(owner, {:lease_locked, self()})

              receive do
                :release_lease -> :ok
              end
            end,
            timeout: 30_000
          )
        end)

      assert_receive {:lease_locked, _}, 2_000

      try do
        reply(socket, commit_ref, Protocol.ack(outgoing))

        original =
          await_state(socket, &(not is_nil(&1.assigns.confirmation_task))).assigns.confirmation_task

        assert Process.read_timer(original.timer) in 1..10_000
        transfer = stage(socket, remote)
        incoming_ref = push(socket, "transfer_commit", %{"transfer_id" => transfer})
        updated = state(socket).assigns.confirmation_task
        assert updated.ref == original.ref
        assert updated.timer == original.timer
        assert_heartbeat(socket)

        Process.sleep(16_100)
        assert_heartbeat(socket)
        deferred = state(socket).assigns.confirmation_task
        assert deferred.ref == original.ref
        assert deferred.timer != original.timer
        assert deferred.session_deadline_deferred
        assert Process.read_timer(original.timer) == false
        assert Process.read_timer(deferred.timer) > 10_000
        send(socket.channel_pid, {:task_deadline, original.ref})
        assert_heartbeat(socket)
        assert state(socket).assigns.confirmation_task.timer == deferred.timer
        send(blocker.pid, :release_lease)
        assert {:ok, {:ok, :ok}} = Task.yield(blocker, 5_000)
        ack = Protocol.ack(remote)
        assert_reply(incoming_ref, :ok, ^ack, 5_000)
        assert_push("ack", ^ack, 5_000)
        await_state(socket, &is_nil(&1.assigns.outgoing))
        assert Store.get("ack", lease_id, peer.id) == Protocol.ack(outgoing)
        assert_heartbeat(socket)
      after
        send(blocker.pid, :release_lease)
        Task.shutdown(blocker, 5_000)
      end
    end)
  end

  test "inventory deadline waits within the budget of an inbound query holding the peer lock", %{
    socket: socket,
    peer: peer,
    note: note
  } do
    Oban.Testing.with_testing_mode(:manual, fn ->
      descriptor = Protocol.ack(Store.get("member", note.id, peer.id)["event"])
      query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}

      expected = %{
        "query_id" => query["query_id"],
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
      }

      ref = push(socket, "sync_negotiate", %{"capabilities" => ["state_query_v1"]})
      assert_reply(ref, :ok, %{"capabilities" => ["state_query_v1"]})
      install_query_barrier(peer.id)
      query_ref = push(socket, "state_query", query)
      assert_receive {:query_peer_locked, worker}, 2_000
      on_exit(fn -> send(worker, :release_query) end)

      try do
        inventory_ref = push(socket, "inventory_start", %{})

        original =
          await_state(socket, &(not is_nil(&1.assigns.inventory_task))).assigns.inventory_task

        query_task = state(socket).assigns.query_task
        assert query_task.pid == worker
        refute original.pid == worker
        remaining = Process.read_timer(query_task.timer)
        assert remaining > 10_000
        send(socket.channel_pid, {:task_deadline, original.ref})

        deferred = state(socket).assigns.inventory_task
        assert Process.alive?(socket.channel_pid)
        assert deferred.ref == original.ref
        refute deferred.timer == original.timer
        assert Process.read_timer(original.timer) == false
        assert Process.read_timer(deferred.timer) in 10_001..(remaining + 10_000)

        # A duplicate expiry must not grant another extension to the same worker.
        send(socket.channel_pid, {:task_deadline, original.ref})
        assert state(socket).assigns.inventory_task.timer == deferred.timer

        heartbeat = %{"inventory_id" => Ecto.UUID.generate(), "total_notes" => 0}
        heartbeat_ref = push(socket, "inventory_complete", heartbeat)
        assert_reply(heartbeat_ref, :ok, %{}, 1_000)
        assert Process.alive?(worker)

        send(worker, :release_query)
        assert_reply(query_ref, :ok, ^expected, 2_000)
        assert_reply(inventory_ref, :ok, %{}, 2_000)

        assert_receive %Phoenix.Socket.Message{event: "state_query", ref: ref, payload: outgoing},
                       2_000

        assert outgoing["items"] == [descriptor]

        reply(socket, ref, %{
          "query_id" => outgoing["query_id"],
          "items" => expected["items"]
        })

        # Even an equal probe must finish the pending note's durable transfer/ACK.
        assert_receive %Phoenix.Socket.Message{
                         event: "transfer_begin",
                         ref: ref,
                         payload: manifest
                       },
                       2_000

        reply(socket, ref, %{})
        event = collect(socket, manifest["transfer_id"], []) |> Jason.decode!()
        assert event["note_id"] == note.id
        assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: ref}, 2_000
        reply(socket, ref, Protocol.ack(event))
        assert_push("inventory_complete", %{"inventory_id" => _, "total_notes" => 1}, 2_000)
        heartbeat_ref = push(socket, "inventory_complete", heartbeat)
        assert_reply(heartbeat_ref, :ok, %{}, 1_000)
        assert Process.alive?(socket.channel_pid)
      after
        send(worker, :release_query)
      end
    end)
  end

  defp install_query_barrier(peer_id) do
    owner = self()
    handler = {__MODULE__, make_ref()}
    held = :atomics.new(1, [])
    dumped_id = Ecto.UUID.dump!(peer_id)

    :ok =
      :telemetry.attach(
        handler,
        [:gsmlg, :repo, :query],
        fn _, _, metadata, _ ->
          if String.contains?(metadata.query, "gao_note_sync_peers") and
               String.ends_with?(metadata.query, "FOR UPDATE") and
               dumped_id in metadata.params and :atomics.compare_exchange(held, 1, 0, 1) == :ok do
            # Repo emits this event after acquiring the row lock. Hold the query
            # here to simulate its subsequent Catalog/S3 I/O on that connection.
            send(owner, {:query_peer_locked, self()})

            receive do
              :release_query -> :ok
            after
              30_000 -> raise "query barrier timed out"
            end
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp install_apply_barrier(event_id) do
    owner = self()
    handler = {__MODULE__, make_ref()}
    key = {__MODULE__, :hold_apply}

    :ok =
      :telemetry.attach_many(
        handler,
        [[:gsmlg, :gao_note, :sync, :apply, :start], [:gsmlg, :repo, :query]],
        fn event, _, metadata, _ ->
          cond do
            event == [:gsmlg, :gao_note, :sync, :apply, :start] and metadata.phase == :transaction and
                metadata.event_id == event_id ->
              Process.put(key, :armed)

            event == [:gsmlg, :repo, :query] and Process.get(key) == :armed and
              String.contains?(metadata.query, "gao_note_sync_peers") and
                String.contains?(metadata.query, "FOR UPDATE") ->
              Process.put(key, :held)
              send(owner, {:apply_peer_locked, self()})

              receive do
                :release_apply -> :ok
              after
                30_000 -> raise "apply barrier timed out"
              end

            true ->
              :ok
          end
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  defp outgoing_commit(socket) do
    ref = push(socket, "inventory_start", %{})
    assert_reply(ref, :ok, %{}, 2_000)

    assert_receive %Phoenix.Socket.Message{event: "transfer_begin", ref: ref, payload: payload},
                   2_000

    reply(socket, ref, %{})
    bytes = collect(socket, payload["transfer_id"], [])
    assert_receive %Phoenix.Socket.Message{event: "transfer_commit", ref: ref}, 2_000
    {Jason.decode!(bytes), ref}
  end

  defp collect(socket, transfer, parts) do
    receive do
      %Phoenix.Socket.Message{
        event: "blob_chunk",
        payload: %{"transfer_id" => ^transfer, "data" => data}
      } ->
        collect(socket, transfer, [Base.decode64!(data) | parts])

      %Phoenix.Socket.Message{event: "blob_end", ref: ref, payload: %{"transfer_id" => ^transfer}} ->
        reply(socket, ref, %{})
        parts |> Enum.reverse() |> IO.iodata_to_binary()
    after
      2_000 -> flunk("outbound event stalled")
    end
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

  defp reply(socket, ref, payload),
    do:
      send(socket.channel_pid, %Phoenix.Socket.Message{
        join_ref: socket.join_ref,
        ref: ref,
        topic: socket.topic,
        event: "phx_reply",
        payload: %{"status" => "ok", "response" => payload}
      })

  defp assert_heartbeat(socket) do
    ref = push(socket, "inventory_complete", %{})
    assert_reply(ref, :ok, %{}, 1_000)
  end

  defp state(socket), do: :sys.get_state(socket.channel_pid, 1_000)
  defp await_state(socket, predicate, attempts \\ 200)
  defp await_state(_socket, _predicate, 0), do: flunk("channel state did not progress")

  defp await_state(socket, predicate, attempts) do
    current = state(socket)

    if predicate.(current),
      do: current,
      else:
        (
          Process.sleep(10)
          await_state(socket, predicate, attempts - 1)
        )
  end

  defp close_channel(socket) do
    channel_ref = Process.monitor(socket.channel_pid)
    guard_ref = Process.monitor(socket.assigns.guard)
    if Process.alive?(socket.channel_pid), do: Process.exit(socket.channel_pid, :shutdown)
    assert_receive {:DOWN, ^channel_ref, :process, _, _}, 5_000
    assert_receive {:DOWN, ^guard_ref, :process, _, _}, 5_000
    refute File.exists?(socket.assigns.staging_root)
  end

  defp remote_event(peer, id, label) do
    stamp = %{"node_id" => peer.id, "millis" => System.system_time(:millisecond), "counter" => 0}

    snapshot = %{
      "title" => "duplex",
      "content" => "remote",
      "labels" => [
        %{"key" => label, "value" => "selected", "description" => "", "value_type" => "text"}
      ],
      "attachments" => [],
      "created_at" => 1,
      "updated_at" => 1,
      "deleted_at" => nil
    }

    %{
      "event_id" => Ecto.UUID.generate(),
      "note_id" => id,
      "kind" => "attach",
      "snapshot" => snapshot,
      "snapshot_hash" => Protocol.snapshot_hash(snapshot),
      "generation" => stamp,
      "control" => stamp,
      "version" => stamp
    }
  end
end
