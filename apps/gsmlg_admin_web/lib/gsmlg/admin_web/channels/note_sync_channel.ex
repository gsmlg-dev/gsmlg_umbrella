defmodule GSMLG.AdminWeb.NoteSyncChannel do
  @moduledoc "Duplex sync transport; outbound requests advance one frame at a time."
  use Phoenix.Channel
  alias GSMLG.GaoNote.Sync
  alias GSMLG.AdminWeb.NoteSync.{InventoryManager, TaskSync}
  alias GSMLG.GaoNote.Sync.{ApplyTelemetry, Engine, Outbound, Protocol, StateQuery, Transfer}
  @deadline 10_000
  @commit_reply_margin 30_000
  @read_base_deadline 30_000
  @read_bytes_per_second 1_048_576
  @preparation_retry_base 5_000
  @preparation_retry_max 300_000
  @source_preparation_errors [
    :too_large,
    :object_unavailable,
    :duplicate_attachment_id,
    :object_too_large,
    :invalid_object_metadata,
    :object_integrity_mismatch,
    :object_checksum_mismatch,
    :object_size_mismatch,
    :backend_changed
  ]
  @task_operations [
    query_task: :state_query,
    manager_page_task: :manager_page,
    inventory_task: :inventory,
    pending_task: :pending,
    blob_task: :blob,
    confirmation_task: :confirmation,
    checkout_task: :checkout,
    read_task: :read,
    recovery_task: :recovery,
    chunk_task: :read_chunk,
    apply_task: :apply
  ]

  @impl true
  def join("note_sync:v1", payload, socket) do
    with {:ok, %{peer: peer, response: response}} <- join_peer(payload) do
      owner = self()

      staging_root =
        Path.join(
          System.tmp_dir!(),
          "gaonote-sync-session-" <>
            Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
        )

      guard = spawn(fn -> monitor(owner, peer, [staging_root]) end)
      Process.send_after(self(), :poll_pending, 1_000)

      socket =
        assign(socket,
          session_peer: peer,
          limit: min(response["max_blob_bytes"], payload["max_blob_bytes"]),
          guard: guard,
          staging_root: staging_root,
          incoming: nil,
          incoming_timer: nil,
          inventory_task: nil,
          query_task: nil,
          query_waiting: nil,
          capabilities: [],
          round_id: nil,
          reconcile_timer: nil,
          round_slots: %{},
          classified_ids: MapSet.new(),
          pending_priority: MapSet.new(),
          pending_streak: 0,
          received_inventory: nil,
          pending_task: nil,
          blob_task: nil,
          confirmation_task: nil,
          apply_task: nil,
          checkout_task: nil,
          read_task: nil,
          recovery_task: nil,
          chunk_task: nil,
          preparation_timer: nil,
          preparation_retries: %{},
          outgoing: nil,
          waiting: nil,
          queue: [],
          inventory_started: false,
          inventory_done: false,
          sequence: 0,
          local_node_id: response["node_id"],
          task_ledger: TaskSync.new(peer.id),
          task_workers: %{},
          outgoing_tasks: %{},
          outgoing_task_history: %{},
          outgoing_task_order: [],
          task_sequence: 0,
          abort_waiters: [],
          sync_manager: nil,
          manager_page_task: nil,
          manager_task_id: nil,
          manager_status_seq: 0,
          manager_last_status: nil,
          manager_last_push_at: nil,
          manager_progress_timer: nil,
          remote_manager_status: nil,
          pending_cursor: nil
        )

      {:ok, Map.put(response, "capabilities", ["state_query_v1", "task_sync_v1"]), socket}
    else
      _ -> {:error, %{code: "invalid_join"}}
    end
  end

  @impl true
  def handle_in("task_submit", command, socket) do
    if task_mode?(socket) and frame_fits?(socket, "task_submit", command, socket.ref) do
      case TaskSync.admit(socket.assigns.task_ledger, command) do
        {kind, ledger, status} when kind in [:new, :replay, :busy] ->
          socket = assign(socket, :task_ledger, ledger)
          push(socket, "task_status", status)
          if kind == :new, do: launch_wire_task(socket, command), else: {:noreply, socket}

        {:error, code} ->
          task_error(socket, command["task_id"], code)
      end
    else
      stop(socket)
    end
  end

  def handle_in("task_get", payload, socket) do
    if task_mode?(socket) and Protocol.exact_keys?(payload, ["task_id"]) do
      case TaskSync.get(socket.assigns.task_ledger, payload["task_id"]) do
        {:ok, status} ->
          push(socket, "task_status", status)

          case socket.assigns.task_workers[payload["task_id"]] do
            %{operation: "reconcile_commit"} = worker ->
              if Process.alive?(worker.pid),
                do: {:noreply, socket},
                else: reconcile_commit(socket, payload["task_id"], worker)

            _ ->
              {:noreply, socket}
          end

        {:error, code} ->
          task_error(socket, payload["task_id"], code)
      end
    else
      stop(socket)
    end
  end

  def handle_in("task_cancel", payload, socket) do
    if task_mode?(socket) and Protocol.exact_keys?(payload, ["task_id"]) do
      id = payload["task_id"]

      case TaskSync.get(socket.assigns.task_ledger, id) do
        {:ok, status} ->
          worker = socket.assigns.task_workers[id]

          cond do
            TaskSync.terminal?(status["state"]) ->
              push(socket, "task_status", status)
              {:noreply, socket}

            worker &&
                worker.operation in ["transfer_commit", "reconcile_commit", "inventory_cleanup"] ->
              {:noreply,
               wire_status(socket, id, "running", "cancellation_pending", status["progress"])}

            worker ->
              Process.exit(worker.pid, :kill)

              workers =
                Map.put(socket.assigns.task_workers, id, Map.put(worker, :cancelling, true))

              {:noreply, assign(socket, :task_workers, workers)}

            true ->
              {:noreply, wire_status(socket, id, "cancelled", "cancelled", %{})}
          end

        {:error, code} ->
          task_error(socket, id, code)
      end
    else
      stop(socket)
    end
  end

  def handle_in("sync_manager_status", payload, socket) do
    if task_mode?(socket) do
      case InventoryManager.accept_status(socket.assigns.remote_manager_status, payload) do
        {:ok, accepted} -> {:noreply, assign(socket, :remote_manager_status, accepted)}
        {:error, code} -> task_error(socket, "invalid", code)
      end
    else
      stop(socket)
    end
  end

  def handle_in("task_status", status, socket), do: receive_task_status(socket, status)

  def handle_in("task_error", error, socket) do
    if task_mode?(socket) and Protocol.exact_keys?(error, ~w(task_id code)) and
         is_binary(error["code"]) and byte_size(error["code"]) <= 64 do
      case socket.assigns.outgoing_tasks[error["task_id"]] do
        %{operation: "transfer_commit"} ->
          # The remote outcome is unresolved. Keep the exact event pending.
          {:noreply, socket}

        nil ->
          {:noreply, socket}

        task ->
          outgoing_task_failed(socket, error["task_id"], task, error["code"])
      end
    else
      stop(socket)
    end
  end

  def handle_in("sync_negotiate", payload, socket) do
    if not socket.assigns.inventory_started and StateQuery.capabilities?(payload) do
      {:reply, {:ok, payload}, assign(socket, :capabilities, payload["capabilities"])}
    else
      stop(socket)
    end
  end

  def handle_in("state_query", payload, %{assigns: %{query_task: nil}} = socket) do
    if negotiated?(socket) and StateQuery.valid_request?(payload) and
         frame_fits?(socket, "state_query", payload, socket.ref) do
      peer = socket.assigns.session_peer
      task = start_task(socket, fn -> Engine.query_state(peer, payload) end, 900_000)
      task = Map.merge(task, %{reply_to: reply_ref(socket), wire_ref: socket.ref})
      {:noreply, assign(socket, :query_task, task)}
    else
      stop(socket)
    end
  end

  def handle_in("inventory_complete", payload, socket) when map_size(payload) > 0 do
    if negotiated?(socket) and Protocol.exact_keys?(payload, ~w(inventory_id total_notes)) and
         Protocol.uuid?(payload["inventory_id"]) and is_integer(payload["total_notes"]) and
         payload["total_notes"] >= 0 and payload["total_notes"] <= 18_446_744_073_709_551_615 do
      {:reply, {:ok, %{}}, assign(socket, :received_inventory, payload)}
    else
      stop(socket)
    end
  end

  def handle_in("inventory_start", payload, socket) when map_size(payload) == 0 do
    if socket.assigns.inventory_started do
      {:reply, {:ok, %{}}, socket}
    else
      peer = socket.assigns.session_peer
      capable = negotiated?(socket)

      task =
        start_task(socket, fn ->
          if capable do
            Engine.inventory_plan(peer)
          else
            with {:ok, ids} <- Sync.inventory(peer),
                 {:ok, pending} <- Sync.pending_ids(peer),
                 do: {:ok, %{ids: ids, pending: if(pending == :busy, do: [], else: pending)}}
          end
        end)

      send(self(), :poll_pending)

      {:noreply,
       assign(socket,
         inventory_started: true,
         round_id: Ecto.UUID.generate(),
         inventory_task: Map.put(task, :reply_to, reply_ref(socket))
       )}
    end
  end

  def handle_in("inventory_complete", payload, socket) when map_size(payload) == 0 do
    if negotiated?(socket), do: stop(socket), else: {:reply, {:ok, %{}}, socket}
  end

  def handle_in("transfer_begin", payload, %{assigns: %{incoming: nil}} = socket) do
    case Transfer.begin(payload, socket.assigns.limit, socket.assigns.staging_root) do
      {:ok, transfer} ->
        {:reply, {:ok, %{}}, socket |> assign(:incoming, transfer) |> touch_incoming()}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_in(event, payload, %{assigns: %{incoming: incoming}} = socket)
      when event in ["attachment_begin", "blob_chunk"] and not is_nil(incoming) and
             is_nil(socket.assigns.apply_task) and is_nil(socket.assigns.blob_task) do
    operation = %{"attachment_begin" => :attachment_begin, "blob_chunk" => :chunk}[event]

    case apply(Transfer, operation, [incoming, payload]) do
      {:ok, transfer} ->
        progressed =
          event != "blob_chunk" or
            transfer.blobs[transfer.active].received > incoming.blobs[incoming.active].received

        socket = assign(socket, :incoming, transfer)
        socket = if progressed, do: touch_incoming(socket), else: socket
        if event == "blob_chunk", do: {:noreply, socket}, else: {:reply, {:ok, %{}}, socket}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_in(
        "blob_end",
        payload,
        %{assigns: %{incoming: incoming, blob_task: nil, apply_task: nil}} = socket
      )
      when not is_nil(incoming) do
    task = start_task(socket, fn -> Transfer.blob_end(incoming, payload) end)
    cancel_incoming_timer(socket)

    {:noreply,
     assign(socket, incoming_timer: nil, blob_task: Map.put(task, :reply_to, reply_ref(socket)))}
  end

  def handle_in(
        "transfer_commit",
        payload,
        %{assigns: %{incoming: incoming, apply_task: nil, blob_task: nil}} = socket
      )
      when not is_nil(incoming) do
    peer = socket.assigns.session_peer

    task =
      start_task(
        socket,
        fn ->
          result =
            with {:ok, event, objects} <-
                   ApplyTelemetry.phase(peer, incoming.event, :assemble, fn ->
                     Transfer.commit(incoming, payload)
                   end),
                 do: Sync.apply(peer, event, objects)

          cleanup =
            ApplyTelemetry.phase(peer, incoming.event, :transfer_cleanup, fn ->
              Transfer.cleanup(incoming)
            end)

          if cleanup == :ok, do: result, else: cleanup
        end,
        commit_deadline(incoming.event, incoming.event_size),
        true
      )

    reply_to = reply_ref(socket)
    cancel_incoming_timer(socket)

    {:noreply,
     assign(socket, incoming_timer: nil, apply_task: Map.put(task, :reply_to, reply_to))}
  end

  def handle_in("ack", payload, socket), do: acknowledge(payload, socket)
  def handle_in("note_rejected", payload, socket), do: reject(payload, socket)

  def handle_in(
        "phx_reply",
        payload,
        %{assigns: %{query_waiting: %{ref: ref} = waiting}} = socket
      )
      when socket.ref == ref do
    if Protocol.exact_keys?(payload, ~w(status response)) and payload["status"] == "ok" and
         StateQuery.valid_response?(waiting.query, payload["response"]) and
         frame_fits?(socket, "phx_reply", payload, ref) do
      cancel_timer(waiting.timer)
      [remote] = payload["response"]["items"]

      checkout_note(
        assign(socket, :query_waiting, nil) |> manager_progress(),
        waiting.descriptor["note_id"],
        socket.assigns.queue,
        {waiting.descriptor, remote}
      )
    else
      stop(socket)
    end
  end

  def handle_in("phx_reply", payload, %{assigns: %{waiting: %{ref: ref} = waiting}} = socket)
      when socket.ref == ref do
    cond do
      not Protocol.exact_keys?(payload, ~w(status response)) ->
        stop(socket)

      payload["status"] == "ok" and waiting.next == :confirmed ->
        acknowledge(payload["response"], socket)

      payload["status"] == "error" and waiting.next == :confirmed ->
        reject(payload["response"], socket)

      payload["status"] == "ok" and payload["response"] == %{} ->
        socket =
          socket
          |> clear_waiting()
          |> assign(:outgoing, %{socket.assigns.outgoing | phase: waiting.next})

        send(self(), :outbound_step)
        {:noreply, socket}

      true ->
        stop(socket)
    end
  end

  def handle_in("phx_reply", %{"response" => %{"query_id" => _}}, socket), do: stop(socket)
  def handle_in("phx_reply", _payload, socket), do: {:noreply, socket}
  def handle_in(_event, _payload, socket), do: stop(socket)

  @impl true
  def handle_info(%Phoenix.Socket.Broadcast{event: "disconnect"} = broadcast, socket) do
    send(socket.transport_pid, broadcast)
    {:stop, {:shutdown, :disconnected}, socket}
  end

  def handle_info(:send_next, %{assigns: %{sync_manager: %{state: "failed"}}} = socket),
    do: {:noreply, socket}

  def handle_info(:send_next, %{assigns: %{inventory_started: false}} = socket),
    do: {:noreply, socket}

  def handle_info(
        :send_next,
        %{assigns: %{inventory_task: task}} = socket
      )
      when not is_nil(task) and is_nil(socket.assigns.sync_manager),
      do: {:noreply, socket}

  def handle_info(
        :send_next,
        %{assigns: %{outgoing: nil, checkout_task: nil, query_waiting: nil, queue: [_ | _]}} =
          socket
      ) do
    {id, rest, socket} = select_next(socket)

    if preparation_deferred?(socket, id) do
      send(self(), :send_next)
      {:noreply, assign(socket, :queue, rest)}
    else
      case socket.assigns.round_slots[id] do
        %{unclassified: true}
        when socket.assigns.capabilities in [
               ["state_query_v1"],
               ["state_query_v1", "task_sync_v1"],
               ["task_sync_v1", "state_query_v1"]
             ] ->
          peer = socket.assigns.session_peer

          task =
            start_task(
              socket,
              fn ->
                {:classified, Engine.classify_inventory_note(peer, id)}
              end,
              900_000
            )

          {:noreply, assign(socket, queue: rest, checkout_task: Map.put(task, :note_id, id))}

        %{descriptor: descriptor}
        when socket.assigns.capabilities in [
               ["state_query_v1"],
               ["state_query_v1", "task_sync_v1"],
               ["task_sync_v1", "state_query_v1"]
             ] ->
          query_note(assign(socket, :queue, rest), descriptor)

        _ ->
          checkout_note(socket, id, rest)
      end
    end
  end

  def handle_info(
        :send_next,
        %{
          assigns: %{
            sync_manager: %{mode: "initial_scan"} = manager,
            outgoing: nil,
            checkout_task: nil,
            query_waiting: nil,
            queue: [],
            manager_page_task: nil
          }
        } = socket
      ) do
    manager = InventoryManager.page_done(manager)
    socket = assign(socket, :sync_manager, manager) |> publish_manager_status()
    peer = socket.assigns.session_peer
    task = start_task(socket, fn -> InventoryManager.read_page(peer, manager) end)
    {:noreply, assign(socket, :manager_page_task, task)}
  end

  def handle_info(
        :send_next,
        %{assigns: %{sync_manager: %{mode: "changes"} = manager, queue: [], outgoing: nil}} =
          socket
      ),
      do:
        {:noreply,
         assign(socket, :sync_manager, %{manager | state: "idle"}) |> publish_manager_status()}

  def handle_info(:send_next, %{assigns: %{sync_manager: manager}} = socket)
      when not is_nil(manager),
      do: {:noreply, socket}

  def handle_info(
        :send_next,
        %{
          assigns: %{
            outgoing: nil,
            checkout_task: nil,
            query_waiting: nil,
            inventory_task: nil,
            queue: [],
            inventory_started: true,
            inventory_done: false
          }
        } = socket
      ) do
    payload =
      if negotiated?(socket),
        do: %{
          "inventory_id" => socket.assigns.round_id,
          "total_notes" => MapSet.size(socket.assigns.classified_ids)
        },
        else: %{}

    socket =
      if task_mode?(socket) do
        case submit_outgoing_task(socket, "inventory_complete", payload) do
          {:ok, _, updated} -> updated
          {:error, updated} -> updated
        end
      else
        push(socket, "inventory_complete", payload)
        socket
      end

    {:noreply, socket |> assign(:inventory_done, true) |> schedule_reconciliation()}
  end

  def handle_info(:reconcile_inventory, %{assigns: %{sync_manager: manager}} = socket)
      when not is_nil(manager),
      do: {:noreply, socket}

  def handle_info(
        :reconcile_inventory,
        %{
          assigns: %{
            inventory_done: true,
            inventory_task: nil,
            outgoing: nil,
            checkout_task: nil,
            query_waiting: nil,
            queue: []
          }
        } = socket
      ) do
    if socket.assigns.reconcile_timer, do: cancel_timer(socket.assigns.reconcile_timer)
    peer = socket.assigns.session_peer
    capable = negotiated?(socket)

    task =
      start_task(socket, fn ->
        if capable, do: Engine.inventory_plan(peer), else: Sync.inventory(peer)
      end)

    {:noreply,
     assign(socket,
       inventory_done: false,
       reconcile_timer: nil,
       round_id: Ecto.UUID.generate(),
       classified_ids: MapSet.new(),
       round_slots: %{},
       inventory_task: task
     )}
  end

  def handle_info(:reconcile_inventory, socket),
    do: {:noreply, schedule_reconciliation(socket)}

  def handle_info(:send_next, socket), do: {:noreply, socket}

  def handle_info(:poll_pending, %{assigns: %{pending_task: nil}} = socket) do
    peer = socket.assigns.session_peer
    cursor = socket.assigns.pending_cursor

    task =
      start_task(socket, fn ->
        if task_mode?(socket), do: Engine.pending_page(peer, cursor), else: Sync.pending_ids(peer)
      end)

    {:noreply, assign(socket, :pending_task, task)}
  end

  def handle_info(:poll_pending, socket), do: {:noreply, socket}

  def handle_info({:wire_progress, id, progress}, socket) do
    case socket.assigns.task_workers[id] do
      nil ->
        {:noreply, socket}

      _ ->
        manager = socket.assigns.sync_manager

        if (id == socket.assigns.manager_task_id and manager) && manager.state != "failed" do
          manager = InventoryManager.observe_source(manager, progress)
          socket = assign(socket, :sync_manager, manager) |> publish_manager_status()

          {:noreply,
           wire_status(socket, id, "running", "checking", InventoryManager.progress(manager))}
        else
          {:noreply, wire_status(socket, id, "running", "checking", progress)}
        end
    end
  end

  def handle_info({ref, result}, %{assigns: %{task_workers: workers}} = socket)
      when is_reference(ref) and map_size(workers) > 0 do
    case Enum.find(workers, fn {_, worker} -> worker.ref == ref end) do
      {id, worker} -> finish_wire_task(socket, id, worker, result)
      nil -> handle_local_task_result(ref, result, socket)
    end
  end

  def handle_info({ref, result}, socket) when is_reference(ref),
    do: handle_local_task_result(ref, result, socket)

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{query_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :query_task, nil)

    case result do
      {:ok, response} ->
        payload = %{"status" => "ok", "response" => response}

        if frame_fits?(socket, "phx_reply", payload, task.wire_ref) do
          reply(task.reply_to, {:ok, response})
          {:noreply, socket}
        else
          stop(socket)
        end

      {:error, reason} ->
        fail(socket, :state_query, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{inventory_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :inventory_task, nil)

    case result do
      {:ok, %{ids: ids, pending: pending}} ->
        if task[:reply_to], do: reply(task.reply_to, {:ok, %{}})
        send(self(), :send_next)
        {:noreply, socket |> enqueue(pending, true) |> enqueue(ids)}

      {:ok, ids} ->
        if task[:reply_to], do: reply(task.reply_to, {:ok, %{}})
        send(self(), :send_next)

        socket =
          if negotiated?(socket) do
            slots = Map.new(ids, &{&1.note_id, &1})

            pending =
              ids
              |> Enum.filter(&(&1.pending and not &1.blocked))
              |> Enum.map(& &1.note_id)

            socket
            |> assign(round_slots: slots, classified_ids: MapSet.new(Map.keys(slots)))
            |> enqueue(pending, true)
            |> enqueue(ids |> Enum.reject(& &1.blocked) |> Enum.map(& &1.note_id))
          else
            enqueue(socket, ids)
          end

        {:noreply, socket}

      {:error, reason} ->
        fail(socket, :inventory, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{pending_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :pending_task, nil)

    case result do
      {:ok, :busy} ->
        Process.send_after(self(), :poll_pending, 1_000)
        {:noreply, socket}

      {:ok, %{ids: ids, cursor: cursor}} ->
        Process.send_after(self(), :poll_pending, 1_000)

        if socket.assigns.inventory_done and socket.assigns.queue == [] and
             is_nil(socket.assigns.outgoing) and
             is_nil(socket.assigns.checkout_task) and is_nil(socket.assigns.query_waiting) do
          manager = %{
            socket.assigns.sync_manager
            | state: if(ids == [], do: "idle", else: "running")
          }

          socket =
            assign(socket, pending_cursor: cursor, round_slots: %{}, sync_manager: manager)
            |> publish_manager_status()
            |> enqueue(ids, true)

          send(self(), :send_next)
          {:noreply, socket}
        else
          {:noreply, socket}
        end

      {:ok, ids} ->
        Process.send_after(self(), :poll_pending, 1_000)
        send(self(), :send_next)

        if negotiated?(socket) do
          if socket.assigns.inventory_done and ids != [], do: send(self(), :reconcile_inventory)
          {:noreply, socket}
        else
          {:noreply, enqueue(socket, ids, true)}
        end

      {:error, reason} ->
        fail(socket, :pending, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{blob_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :blob_task, nil)

    case result do
      {:ok, transfer} ->
        if task.reply_to, do: reply(task.reply_to, {:ok, %{}})
        {:noreply, socket |> assign(:incoming, transfer) |> touch_incoming()}

      {:error, reason} ->
        fail(socket, :blob, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{confirmation_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :confirmation_task, nil)

    case result do
      :ok -> next_note(socket)
      {:error, reason} -> fail(socket, :confirmation, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{checkout_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :checkout_task, nil)

    case result do
      {:classified, {:ok, %{blocked: false, descriptor: descriptor} = slot}}
      when not is_nil(descriptor) ->
        slots = Map.put(socket.assigns.round_slots, task.note_id, slot)
        query_note(assign(socket, :round_slots, slots), descriptor)

      {:classified, {:ok, _blocked_or_superseded}} ->
        send(self(), :send_next)
        {:noreply, socket}

      {:classified, {:error, reason}} ->
        fail(socket, :checkout, reason, task)

      {:ok, checkout} ->
        prepare_outgoing(checkout, socket)

      result when result in [:equal, :superseded, :empty] ->
        send(self(), :send_next)
        {:noreply, clear_preparation_retry(socket, task.note_id)}

      {:error, reason} when reason in @source_preparation_errors or is_binary(reason) ->
        defer_checkout(socket, task.note_id, reason)

      {:error, {:unexpected_response, _} = reason} ->
        defer_checkout(socket, task.note_id, reason)

      {:error, reason} ->
        fail(socket, :checkout, reason, task)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{apply_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    incoming = socket.assigns.incoming
    socket = assign(socket, incoming: nil, apply_task: nil)

    case result do
      {:ok, ack} ->
        push(socket, "ack", ack)
        if task.reply_to, do: reply(task.reply_to, {:ok, ack})
        {:noreply, socket}

      {:error, {:note_rejected, reason}}
      when reason in [
             :validation_failed,
             :catalog_conflict,
             "validation_failed",
             "catalog_conflict"
           ] ->
        event = incoming.event

        rejection = %{
          "code" => "note_rejected",
          "event_id" => event["event_id"],
          "note_id" => event["note_id"],
          "reason" => to_string(reason)
        }

        if task.reply_to,
          do: reply(task.reply_to, {:error, rejection}),
          else: push(socket, "note_rejected", rejection)

        {:noreply, socket}

      {:error, reason} ->
        fail(socket, :apply, reason, %{note_id: get_in(incoming, [:event, "note_id"])})
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{read_task: %{ref: ref} = task}} = socket
      ) do
    case result do
      {:ok, file} ->
        finish_task(socket, task)

        outgoing = %{
          socket.assigns.outgoing
          | preparing: task.remaining,
            prepared: Map.put(socket.assigns.outgoing.prepared, task.attachment["id"], file),
            phase: :prepare
        }

        send(self(), :outbound_step)
        {:noreply, assign(socket, outgoing: outgoing, read_task: nil)}

      {:error, reason} ->
        preparation_failure(socket, :read, reason, task)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{recovery_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :recovery_task, nil)

    case result do
      :ok ->
        send(self(), :send_next)
        {:noreply, assign(socket, :outgoing, nil)}

      {:error, reason} ->
        fail(socket, :recovery, reason)
    end
  end

  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{chunk_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :chunk_task, nil)

    case result do
      {:ok, bytes} ->
        outgoing = %{socket.assigns.outgoing | phase: :chunks}
        send_chunk(assign(socket, :outgoing, outgoing), bytes)

      {:error, reason} ->
        fail(socket, :read_chunk, reason, task)
    end
  end

  def handle_info({kind, _}, %{assigns: %{capabilities: capabilities}} = socket)
      when kind in [
             :task_deadline,
             :query_deadline,
             :request_deadline,
             :incoming_deadline,
             :preparation_deadline
           ] and
             capabilities in [
               ["state_query_v1", "task_sync_v1"],
               ["task_sync_v1", "state_query_v1"]
             ],
      do: {:noreply, socket}

  def handle_info({:task_deadline, ref}, socket) do
    case active_task(socket, ref) do
      {operation, task}
      when operation in [:inventory, :pending, :checkout, :confirmation, :recovery] ->
        session_task_deadline(socket, operation, task)

      {:read, task} ->
        preparation_failure(socket, :read, :task_timeout, task)

      {operation, task} ->
        fail(socket, operation, :task_timeout, task)

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, socket) do
    case Enum.find(socket.assigns[:task_workers] || %{}, fn {_, task} -> task.ref == ref end) do
      {id, worker} -> wire_task_down(socket, id, worker, reason)
      nil -> local_task_down(socket, ref, reason)
    end
  end

  def handle_info(:outbound_step, %{assigns: %{outgoing: outgoing, waiting: nil}} = socket)
      when not is_nil(outgoing) and outgoing.phase in [:prepare, :begin, :chunks, :next_blob],
      do: step(outgoing, socket)

  def handle_info(:outbound_step, socket), do: {:noreply, socket}

  def handle_info({:query_deadline, ref}, %{assigns: %{query_waiting: %{ref: ref}}} = socket),
    do: stop(socket)

  def handle_info({:query_deadline, _ref}, socket), do: {:noreply, socket}

  def handle_info({:request_deadline, ref}, %{assigns: %{waiting: %{ref: ref}}} = socket),
    do: stop(socket)

  def handle_info(
        {:incoming_deadline, token},
        %{assigns: %{incoming_timer: {token, _timer}}} = socket
      ),
      do: stop(socket)

  def handle_info({:request_deadline, _}, socket), do: {:noreply, socket}
  def handle_info({:incoming_deadline, _}, socket), do: {:noreply, socket}

  def handle_info(
        {:preparation_deadline, token},
        %{assigns: %{preparation_timer: {token, _timer}}} = socket
      ),
      do: preparation_failure(socket, :prepare, :task_timeout)

  def handle_info({:preparation_deadline, _}, socket), do: {:noreply, socket}

  # A cancelled task may already have sent its result before its monitor was removed.
  def handle_info(
        {:local_result, ref, result},
        %{assigns: %{manager_page_task: %{ref: ref} = task}} = socket
      ) do
    finish_task(socket, task)
    socket = assign(socket, :manager_page_task, nil)

    case result do
      {:ok, :waiting} ->
        Process.send_after(self(), :send_next, 100)
        {:noreply, socket}

      {:ok, {:done, source}} ->
        manager = InventoryManager.observe_source(socket.assigns.sync_manager, source)
        manager = %{manager | mode: "changes"}

        payload = %{
          "inventory_id" => manager.round_id,
          "total_notes" => manager.source["notes_scanned"]
        }

        socket =
          assign(socket,
            sync_manager: manager,
            inventory_done: true,
            round_slots: %{},
            classified_ids: MapSet.new()
          )
          |> publish_manager_status()

        case submit_outgoing_task(socket, "inventory_complete", payload) do
          {:ok, _, updated} -> {:noreply, updated}
          {:error, updated} -> {:noreply, updated}
        end

      {:ok, %{ids: ids, slots: slots, source: source}} ->
        manager =
          socket.assigns.sync_manager
          |> InventoryManager.observe_source(source)
          |> InventoryManager.page_loaded(length(ids), length(slots))

        pending = slots |> Enum.filter(&(&1.pending and not &1.blocked)) |> Enum.map(& &1.note_id)

        socket =
          socket
          |> assign(sync_manager: manager, round_slots: Map.new(slots, &{&1.note_id, &1}))
          |> enqueue(pending, true)
          |> enqueue(slots |> Enum.reject(& &1.blocked) |> Enum.map(& &1.note_id))

        send(self(), :send_next)
        {:noreply, socket}

      {:error, reason} ->
        fail(socket, :manager_page, reason)
    end
  end

  def handle_info(
        {:publish_manager, token},
        %{assigns: %{manager_progress_timer: {token, _}}} = socket
      ),
      do: {:noreply, assign(socket, :manager_progress_timer, nil) |> publish_manager_status()}

  def handle_info({:publish_manager, _token}, socket), do: {:noreply, socket}

  def handle_info({:manager_ready, round_id}, socket) do
    if socket.assigns.sync_manager && socket.assigns.sync_manager.state != "failed" &&
         socket.assigns.sync_manager.round_id == round_id,
       do: send(self(), :send_next)

    {:noreply, socket}
  end

  def handle_info({:local_result, ref, _result}, socket) when is_reference(ref),
    do: {:noreply, socket}

  defp checkout_note(socket, id, rest, compared \\ nil) do
    peer = socket.assigns.session_peer
    limit = socket.assigns.limit

    task =
      start_task(socket, fn ->
        result =
          case compared do
            nil -> Sync.checkout(peer, id)
            {descriptor, remote} -> Engine.checkout_compared(peer, descriptor, remote)
          end

        case result do
          {:ok, checkout} ->
            bytes = Jason.encode!(checkout.event)

            attachments = (checkout.event["snapshot"] || %{})["attachments"] || []
            total = Enum.reduce(attachments, byte_size(bytes), &(&1["size_bytes"] + &2))

            if Protocol.validate_event(checkout.event) == :ok and total <= limit do
              {:ok,
               Map.merge(checkout, %{metadata: bytes, metadata_hash: Protocol.sha256(bytes)})}
            else
              Sync.release_lease(peer, checkout.lease_id)
              :empty
            end

          other ->
            other
        end
      end)

    {:noreply, assign(socket, queue: rest, checkout_task: Map.put(task, :note_id, id))}
  end

  defp schedule_reconciliation(socket) do
    if socket.assigns.reconcile_timer, do: cancel_timer(socket.assigns.reconcile_timer)
    assign(socket, :reconcile_timer, Process.send_after(self(), :reconcile_inventory, 60_000))
  end

  defp negotiated?(socket), do: "state_query_v1" in (socket.assigns[:capabilities] || [])
  defp task_mode?(socket), do: "task_sync_v1" in (socket.assigns[:capabilities] || [])

  defp query_note(socket, descriptor) do
    if task_mode?(socket) do
      query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}

      case submit_outgoing_task(socket, "state_query", query) do
        {:ok, id, socket} ->
          {:noreply,
           assign(socket, :query_waiting, %{
             task_id: id,
             query: query,
             descriptor: descriptor,
             timer: nil
           })}

        {:error, socket} ->
          {:noreply, socket}
      end
    else
      legacy_query_note(socket, descriptor)
    end
  end

  defp legacy_query_note(socket, descriptor) do
    sequence = socket.assigns.sequence + 1
    ref = "sync-#{sequence}"
    query = %{"query_id" => Ecto.UUID.generate(), "items" => [descriptor]}

    if frame_fits?(socket, "state_query", query, ref) do
      message = %Phoenix.Socket.Message{
        join_ref: socket.join_ref,
        ref: ref,
        topic: socket.topic,
        event: "state_query",
        payload: query
      }

      send(socket.transport_pid, socket.serializer.encode!(message))
      timer = Process.send_after(self(), {:query_deadline, ref}, 930_000)

      {:noreply,
       assign(socket,
         sequence: sequence,
         query_waiting: %{ref: ref, query: query, descriptor: descriptor, timer: timer}
       )}
    else
      stop(socket)
    end
  end

  defp local_task_down(socket, ref, reason) do
    case active_task(socket, ref) do
      {:read, task} ->
        preparation_failure(socket, :read, reason, Map.put(task, :failure_type, :task_exit))

      {operation, task} ->
        fail(socket, operation, reason, Map.put(task, :failure_type, :task_exit))

      nil ->
        {:noreply, socket}
    end
  end

  defp publish_manager_status(%{assigns: %{sync_manager: nil}} = socket), do: socket

  defp publish_manager_status(socket) do
    progress = InventoryManager.progress(socket.assigns.sync_manager)

    if progress == socket.assigns.manager_last_status do
      socket
    else
      sequence = socket.assigns.manager_status_seq + 1

      payload = %{
        "round_id" => socket.assigns.sync_manager.round_id,
        "status_seq" => sequence,
        "progress" => progress
      }

      push(socket, "sync_manager_status", payload)

      if socket.assigns.manager_progress_timer,
        do: cancel_timer(elem(socket.assigns.manager_progress_timer, 1))

      assign(socket,
        manager_status_seq: sequence,
        manager_last_status: progress,
        manager_last_push_at: System.monotonic_time(:millisecond),
        manager_progress_timer: nil
      )
    end
  end

  defp manager_progress(%{assigns: %{sync_manager: nil}} = socket), do: socket
  defp manager_progress(%{assigns: %{sync_manager: %{state: "failed"}}} = socket), do: socket

  defp manager_progress(socket) do
    manager = %{
      socket.assigns.sync_manager
      | last_progress_at: System.system_time(:millisecond),
        state: "running"
    }

    socket = assign(socket, :sync_manager, manager)
    elapsed = System.monotonic_time(:millisecond) - (socket.assigns.manager_last_push_at || 0)

    cond do
      elapsed >= 250 ->
        publish_manager_status(socket)

      socket.assigns.manager_progress_timer ->
        socket

      true ->
        token = make_ref()
        timer = Process.send_after(self(), {:publish_manager, token}, 250 - elapsed)
        assign(socket, :manager_progress_timer, {token, timer})
    end
  end

  defp manager_failed(%{assigns: %{sync_manager: nil}} = socket, _error), do: socket

  defp manager_failed(socket, error) do
    manager = %{socket.assigns.sync_manager | state: "failed", error: error}
    assign(socket, :sync_manager, manager) |> publish_manager_status()
  end

  defp task_error(socket, id, code) do
    id = if is_binary(id) and byte_size(id) <= 57, do: id, else: "invalid"
    push(socket, "task_error", %{"task_id" => id, "code" => code})
    {:noreply, socket}
  end

  defp wire_status(socket, id, state, phase, progress, result \\ nil, error \\ nil) do
    candidate = %{
      "task_id" => id,
      "status_seq" => 18_446_744_073_709_551_615,
      "state" => state,
      "phase" => phase,
      "progress" => progress,
      "result" => result,
      "error" => error
    }

    {state, phase, progress, result, error} =
      if frame_fits?(socket, "task_status", candidate, nil) do
        {state, phase, progress, result, error}
      else
        {"failed", "failed", %{}, nil, %{"code" => "response_too_large", "retryable" => false}}
      end

    {ledger, status} =
      TaskSync.update(socket.assigns.task_ledger, id, state, phase, progress, result, error)

    if frame_fits?(socket, "task_status", status, nil) do
      push(socket, "task_status", status)
      assign(socket, :task_ledger, ledger)
    else
      {ledger, failed} =
        TaskSync.update(socket.assigns.task_ledger, id, "failed", "failed", %{}, nil, %{
          "code" => "response_too_large",
          "retryable" => false
        })

      push(socket, "task_status", failed)
      assign(socket, :task_ledger, ledger)
    end
  end

  defp launch_wire_task(socket, command) do
    id = command["task_id"]
    operation = command["operation"]
    payload = command["payload"]
    peer = socket.assigns.session_peer
    incoming = socket.assigns.incoming
    owner = self()

    manager =
      if operation == "inventory_start",
        do: InventoryManager.new(socket.assigns.staging_root, Ecto.UUID.generate()),
        else: nil

    work =
      case operation do
        "inventory_start" when map_size(payload) == 0 ->
          if socket.assigns.inventory_started and not socket.assigns.inventory_done and
               socket.assigns.sync_manager.state != "failed" do
            :busy
          else
            fn ->
              notify = fn progress ->
                if progress["pages_scanned"] == 1,
                  do: send(owner, {:manager_ready, manager.round_id})

                now = System.monotonic_time(:millisecond)
                previous = Process.get(:inventory_progress_at)

                if is_nil(previous) or progress["scan_complete"] or now - previous >= 250 do
                  send(owner, {:wire_progress, id, progress})
                  Process.put(:inventory_progress_at, now)
                end
              end

              previous = socket.assigns.sync_manager

              with {:ok, _} <- if(previous, do: File.rm_rf(previous.directory), else: {:ok, []}) do
                InventoryManager.scan(peer, manager, notify)
              end
            end
          end

        "state_query" ->
          if StateQuery.valid_request?(payload),
            do: fn -> Engine.query_state(peer, payload) end,
            else: :invalid

        "transfer_begin" ->
          if is_nil(incoming),
            do: fn ->
              Transfer.begin(payload, socket.assigns.limit, socket.assigns.staging_root)
            end,
            else: :busy

        "attachment_begin" when not is_nil(incoming) ->
          fn -> Transfer.attachment_begin(incoming, payload) end

        "blob_chunk" when not is_nil(incoming) ->
          fn -> Transfer.chunk(incoming, payload) end

        "blob_end" when not is_nil(incoming) ->
          fn -> Transfer.blob_end(incoming, payload) end

        "transfer_commit" when not is_nil(incoming) ->
          fn ->
            with {:ok, event, objects} <- Transfer.commit(incoming, payload) do
              case Sync.apply(peer, event, objects) do
                {:ok, ack} ->
                  Transfer.cleanup(incoming)
                  {:ok, ack}

                {:error, _} = error ->
                  if exact_receipt?(peer, event) do
                    Transfer.cleanup(incoming)
                    {:ok, Protocol.ack(event)}
                  else
                    error
                  end
              end
            end
          end

        "inventory_complete" ->
          if Protocol.exact_keys?(payload, ~w(inventory_id total_notes)) and
               Protocol.uuid?(payload["inventory_id"]) and
               is_integer(payload["total_notes"]) and
               payload["total_notes"] in 0..18_446_744_073_709_551_615,
             do: fn -> {:ok, %{}} end,
             else: :invalid

        "transfer_abort" ->
          cond do
            not Protocol.exact_keys?(payload, ["transfer_id"]) or
                not Protocol.uuid?(payload["transfer_id"]) ->
              :invalid

            Enum.any?(socket.assigns.task_workers, fn {_, w} ->
              w.operation in ~w(transfer_begin attachment_begin blob_chunk blob_end transfer_commit reconcile_commit) and
                  w.payload["transfer_id"] == payload["transfer_id"]
            end) ->
              :await_apply

            is_nil(incoming) ->
              fn -> {:ok, %{}} end

            incoming.id != payload["transfer_id"] ->
              :invalid

            true ->
              fn -> with :ok <- Transfer.cleanup(incoming), do: {:ok, %{}} end
          end

        _ ->
          :invalid
      end

    case work do
      :await_apply ->
        {:noreply,
         socket
         |> wire_status(id, "running", "cancellation_pending", %{})
         |> assign(:abort_waiters, socket.assigns.abort_waiters ++ [id])}

      status when status in [:invalid, :busy] ->
        {:noreply,
         wire_status(socket, id, "failed", "failed", %{}, nil, %{
           "code" => if(status == :busy, do: "busy", else: "validation_failed"),
           "retryable" => status == :busy
         })}

      work ->
        task = start_task(socket, work, @deadline, operation == "transfer_commit")

        worker =
          Map.merge(task, %{
            operation: operation,
            payload: Map.take(payload, ~w(transfer_id blob_id inventory_id total_notes)),
            incoming: incoming,
            cancelling: false
          })

        socket = assign(socket, :task_workers, Map.put(socket.assigns.task_workers, id, worker))

        socket =
          if operation == "inventory_start" do
            assign(socket,
              inventory_started: true,
              inventory_done: false,
              inventory_task: task,
              round_id: manager.round_id,
              sync_manager: manager,
              manager_task_id: id,
              classified_ids: MapSet.new(),
              round_slots: %{}
            )
          else
            socket
          end

        progress = if manager, do: InventoryManager.progress(manager), else: %{}
        {:noreply, wire_status(socket, id, "running", TaskSync.phase(operation), progress)}
    end
  end

  defp finish_wire_task(
         socket,
         id,
         %{operation: "reconcile_commit"} = worker,
         {:reconciled, received}
       ) do
    finish_task(socket, worker)

    if received do
      socket = assign(socket, :task_workers, Map.delete(socket.assigns.task_workers, id))

      wire_task_success(
        socket,
        id,
        %{worker | operation: "transfer_commit"},
        Protocol.ack(worker.incoming.event)
      )
    else
      # No durable receipt proves success. Keep this bounded slot quarantined.
      {:noreply, socket}
    end
  end

  defp finish_wire_task(socket, id, %{operation: "inventory_cleanup"} = worker, result) do
    finish_task(socket, worker)
    socket = assign(socket, :task_workers, Map.delete(socket.assigns.task_workers, id))

    {state, error} =
      if match?({:ok, _}, result),
        do: {worker.terminal_state, worker.terminal_error},
        else: {"failed", %{"code" => "storage", "retryable" => true}}

    socket = if error, do: manager_failed(socket, error), else: socket
    {:noreply, wire_status(socket, id, state, state, %{}, nil, error)}
  end

  defp finish_wire_task(socket, id, worker, result) do
    finish_task(socket, worker)
    socket = assign(socket, :task_workers, Map.delete(socket.assigns.task_workers, id))

    cond do
      worker.cancelling ->
        cancel_wire_task(socket, id, worker, result)

      worker.operation == "inventory_start" and not match?({:ok, _}, result) ->
        begin_inventory_cleanup(socket, id, "failed", wire_error(result))

      match?({:ok, _}, result) ->
        {:ok, value} = result
        wire_task_success(socket, id, worker, value)

      true ->
        reason =
          case result do
            {:error, reason} -> reason
            _ -> :task_failed
          end

        socket = cleanup_failed_wire(socket, worker)
        {:noreply, wire_status(socket, id, "failed", "failed", %{}, nil, wire_error(reason))}
    end
  end

  defp wire_task_success(socket, id, %{operation: "inventory_start"}, source) do
    manager = InventoryManager.observe_source(socket.assigns.sync_manager, source)

    socket =
      assign(socket, inventory_task: nil, sync_manager: manager) |> publish_manager_status()

    socket =
      wire_status(socket, id, "succeeded", "complete", InventoryManager.progress(manager), %{})

    send(self(), :send_next)
    {:noreply, socket}
  end

  defp wire_task_success(socket, id, %{operation: op} = worker, value)
       when op in ~w(transfer_begin attachment_begin blob_chunk blob_end) do
    socket = assign(socket, :incoming, value)

    result =
      if op == "blob_chunk" do
        %{
          "transfer_id" => value.id,
          "blob_id" => worker.payload["blob_id"],
          "received_bytes" => value.blobs[worker.payload["blob_id"]].received
        }
      else
        %{}
      end

    progress =
      if op == "blob_chunk",
        do: Map.put(result, "total_bytes", value.blobs[worker.payload["blob_id"]].size),
        else: %{}

    socket = wire_status(socket, id, "succeeded", "complete", progress, result)

    case socket.assigns.abort_waiters do
      [abort_id] ->
        socket = assign(socket, :abort_waiters, [])

        launch_wire_task(socket, %{
          "task_id" => abort_id,
          "operation" => "transfer_abort",
          "payload" => %{"transfer_id" => value.id}
        })

      _ ->
        {:noreply, socket}
    end
  end

  defp wire_task_success(socket, id, %{operation: "transfer_commit"} = worker, ack) do
    # The durable receipt is committed before the exact ACK status is published.
    :ok = Transfer.cleanup(worker.incoming)

    socket =
      socket |> assign(:incoming, nil) |> wire_status(id, "succeeded", "complete", %{}, ack)

    socket =
      Enum.reduce(socket.assigns.abort_waiters, socket, fn waiter, state ->
        wire_status(state, waiter, "succeeded", "complete", %{}, %{})
      end)

    {:noreply, assign(socket, :abort_waiters, [])}
  end

  defp wire_task_success(socket, id, %{operation: "transfer_abort"}, _) do
    {:noreply,
     socket |> assign(:incoming, nil) |> wire_status(id, "succeeded", "complete", %{}, %{})}
  end

  defp wire_task_success(socket, id, %{operation: "inventory_complete", payload: payload}, result) do
    {:noreply,
     socket
     |> assign(:received_inventory, payload)
     |> wire_status(id, "succeeded", "complete", %{}, result)}
  end

  defp wire_task_success(socket, id, _worker, value),
    do: {:noreply, wire_status(socket, id, "succeeded", "complete", %{}, value)}

  defp wire_task_down(socket, id, %{operation: "transfer_commit"} = worker, _reason) do
    finish_task(socket, worker)

    socket =
      wire_status(socket, id, "running", "outcome_unknown", %{}, nil, %{
        "code" => "outcome_unknown",
        "retryable" => false
      })

    reconcile_commit(socket, id, worker)
  end

  defp wire_task_down(socket, id, %{operation: "reconcile_commit"} = worker, _reason) do
    finish_task(socket, worker)

    {:noreply,
     wire_status(socket, id, "running", "outcome_unknown", %{}, nil, %{
       "code" => "outcome_unknown",
       "retryable" => false
     })}
  end

  defp wire_task_down(socket, id, %{operation: "inventory_start"} = worker, reason) do
    finish_task(socket, worker)
    socket = assign(socket, :task_workers, Map.delete(socket.assigns.task_workers, id))
    state = if worker.cancelling, do: "cancelled", else: "failed"
    error = if worker.cancelling, do: nil, else: wire_error(reason)
    begin_inventory_cleanup(socket, id, state, error)
  end

  defp wire_task_down(socket, id, worker, reason) do
    finish_task(socket, worker)
    socket = assign(socket, :task_workers, Map.delete(socket.assigns.task_workers, id))
    socket = cleanup_failed_wire(socket, worker)

    if worker.cancelling do
      {:noreply, wire_status(socket, id, "cancelled", "cancelled", %{})}
    else
      {:noreply, wire_status(socket, id, "failed", "failed", %{}, nil, wire_error(reason))}
    end
  end

  defp reconcile_commit(socket, id, worker) do
    peer = socket.assigns.session_peer
    event = worker.incoming.event

    task =
      start_task(
        socket,
        fn ->
          received = exact_receipt?(peer, event)
          if received, do: Transfer.cleanup(worker.incoming)
          {:reconciled, received}
        end,
        @deadline,
        true
      )

    updated = Map.merge(worker, task) |> Map.put(:operation, "reconcile_commit")
    {:noreply, assign(socket, :task_workers, Map.put(socket.assigns.task_workers, id, updated))}
  end

  defp cancel_wire_task(socket, id, %{operation: "inventory_start"}, _result),
    do: begin_inventory_cleanup(socket, id, "cancelled", nil)

  defp cancel_wire_task(socket, id, worker, result) do
    # A disposable worker might have completed before cancellation reached it.
    if worker.operation in ~w(transfer_begin attachment_begin blob_chunk blob_end) do
      case result do
        {:ok, transfer} -> Transfer.cleanup(transfer)
        _ -> :ok
      end
    end

    socket = cleanup_failed_wire(socket, worker)
    {:noreply, wire_status(socket, id, "cancelled", "cancelled", %{})}
  end

  defp begin_inventory_cleanup(socket, id, terminal_state, terminal_error) do
    if socket.assigns.manager_page_task do
      Task.Supervisor.terminate_child(GSMLG.TaskSupervisor, socket.assigns.manager_page_task.pid)
      finish_task(socket, socket.assigns.manager_page_task)
    end

    manager = socket.assigns.sync_manager

    task =
      start_task(socket, fn ->
        if manager, do: File.rm_rf(manager.directory), else: {:ok, []}
      end)

    worker =
      Map.merge(task, %{
        operation: "inventory_cleanup",
        cancelling: false,
        terminal_state: terminal_state,
        terminal_error: terminal_error
      })

    {:noreply,
     assign(socket,
       inventory_task: nil,
       inventory_started: false,
       inventory_done: false,
       manager_page_task: nil,
       sync_manager:
         if(manager,
           do: %{
             manager
             | state: "failed",
               error: terminal_error || %{"code" => "cancelled", "retryable" => true}
           }
         ),
       manager_task_id: nil,
       queue: [],
       round_slots: %{},
       pending_priority: MapSet.new(),
       task_workers: Map.put(socket.assigns.task_workers, id, worker)
     )
     |> publish_manager_status()}
  end

  defp cleanup_failed_wire(socket, %{operation: op, incoming: incoming})
       when op in ~w(transfer_begin attachment_begin blob_chunk blob_end transfer_commit transfer_abort) do
    Transfer.cleanup(incoming)
    socket = assign(socket, :incoming, nil)

    socket =
      Enum.reduce(socket.assigns.abort_waiters, socket, fn id, state ->
        wire_status(state, id, "succeeded", "complete", %{}, %{})
      end)

    assign(socket, :abort_waiters, [])
  end

  defp cleanup_failed_wire(socket, _), do: socket

  defp wire_error(reason) do
    code =
      case reason do
        {:note_rejected, code}
        when code in [
               "validation_failed",
               "catalog_conflict",
               :validation_failed,
               :catalog_conflict
             ] ->
          to_string(code)

        :validation_failed ->
          "validation_failed"

        :unauthorized ->
          "unauthorized"

        :obsolete_session ->
          "obsolete_session"

        :event_id_conflict ->
          "event_id_conflict"

        :busy ->
          "busy"

        _ ->
          "operation_failed"
      end

    %{"code" => code, "retryable" => code in ["busy", "operation_failed"]}
  end

  defp exact_receipt?(peer, event) do
    alias GSMLG.GaoNote.Sync.Store
    digest = Protocol.sha256(Protocol.canonical_json(event))

    case Store.transaction(fn -> Store.get("received", event["event_id"], peer.id) end) do
      {:ok, %{"event_hash" => ^digest}} -> true
      _ -> false
    end
  end

  defp submit_outgoing_task(socket, operation, payload) do
    sequence = socket.assigns.task_sequence + 1
    id = "#{socket.assigns.local_node_id}:#{sequence}"
    command = %{"task_id" => id, "operation" => operation, "payload" => payload}

    if map_size(socket.assigns.outgoing_tasks) < 4 and
         frame_fits?(socket, "task_submit", command, nil) do
      push(socket, "task_submit", command)
      task = %{operation: operation, payload: Map.drop(payload, ["data"]), status: nil}

      {:ok, id,
       assign(socket,
         task_sequence: sequence,
         outgoing_tasks: Map.put(socket.assigns.outgoing_tasks, id, task)
       )}
    else
      {:error, socket}
    end
  end

  defp receive_task_status(socket, status) do
    id = status["task_id"]
    task = socket.assigns.outgoing_tasks[id]
    previous = if task, do: task.status, else: socket.assigns.outgoing_task_history[id]

    cond do
      not task_mode?(socket) or not frame_fits?(socket, "task_status", status, nil) ->
        stop(socket)

      is_nil(task) and is_nil(previous) ->
        task_error(socket, id, "unknown_task")

      task && not valid_task_result?(socket, task, status) ->
        task_error(socket, id, "invalid_result")

      true ->
        case TaskSync.accept_status(previous, status) do
          {:error, _} ->
            task_error(socket, id, "invalid_status")

          {:ok, accepted} when accepted != status ->
            {:noreply, socket}

          {:ok, _} when is_nil(task) ->
            {:noreply, socket}

          {:ok, accepted} ->
            socket =
              assign(
                socket,
                :outgoing_tasks,
                Map.put(socket.assigns.outgoing_tasks, id, %{task | status: accepted})
              )

            if TaskSync.terminal?(accepted["state"]) do
              socket = retire_outgoing_task(socket, id, accepted)

              if accepted["state"] == "succeeded",
                do: outgoing_task_succeeded(socket, id, task, accepted["result"]),
                else:
                  outgoing_task_failed(
                    socket,
                    id,
                    task,
                    get_in(accepted, ["error", "code"]) || "cancelled"
                  )
            else
              {:noreply, socket}
            end
        end
    end
  end

  defp valid_task_result?(socket, task, %{"state" => "succeeded", "result" => result}) do
    case task.operation do
      "state_query" ->
        StateQuery.valid_response?(task.payload, result)

      "transfer_commit" ->
        socket.assigns.outgoing && result == Protocol.ack(socket.assigns.outgoing.event)

      "blob_chunk" ->
        expected =
          Map.take(task.payload, ~w(transfer_id blob_id))
          |> Map.put(
            "received_bytes",
            socket.assigns.waiting && socket.assigns.waiting[:received_bytes]
          )

        result == expected

      _ ->
        result == %{}
    end
  end

  defp valid_task_result?(_socket, _task, _status), do: true

  defp retire_outgoing_task(socket, id, status) do
    order = socket.assigns.outgoing_task_order ++ [id]
    history = Map.put(socket.assigns.outgoing_task_history, id, status)

    {order, history} =
      if length(order) > 64 do
        [old | rest] = order
        {rest, Map.delete(history, old)}
      else
        {order, history}
      end

    assign(socket,
      outgoing_tasks: Map.delete(socket.assigns.outgoing_tasks, id),
      outgoing_task_order: order,
      outgoing_task_history: history
    )
  end

  defp outgoing_task_succeeded(socket, id, %{operation: "state_query"}, result) do
    waiting = socket.assigns.query_waiting

    if (waiting && waiting[:task_id] == id) and StateQuery.valid_response?(waiting.query, result) do
      [remote] = result["items"]

      checkout_note(
        assign(socket, :query_waiting, nil),
        waiting.descriptor["note_id"],
        socket.assigns.queue,
        {waiting.descriptor, remote}
      )
    else
      task_error(socket, id, "invalid_result")
    end
  end

  defp outgoing_task_succeeded(socket, _id, %{operation: "inventory_complete"}, result) do
    if result == %{}, do: {:noreply, socket}, else: stop(socket)
  end

  defp outgoing_task_succeeded(socket, _id, %{operation: "transfer_abort"}, result) do
    if result == %{}, do: recover_outgoing(socket, :remote_task_failed), else: stop(socket)
  end

  defp outgoing_task_succeeded(socket, id, %{operation: "blob_chunk", payload: payload}, result) do
    waiting = socket.assigns.waiting

    expected = %{
      "transfer_id" => payload["transfer_id"],
      "blob_id" => payload["blob_id"],
      "received_bytes" => waiting && waiting[:received_bytes]
    }

    if (waiting && waiting[:task_id] == id) and result == expected do
      outgoing = %{socket.assigns.outgoing | offset: result["received_bytes"]}
      send(self(), :outbound_step)
      {:noreply, socket |> clear_waiting() |> assign(:outgoing, outgoing) |> manager_progress()}
    else
      task_error(socket, id, "invalid_result")
    end
  end

  defp outgoing_task_succeeded(socket, id, %{operation: "transfer_commit"}, result) do
    if socket.assigns.waiting && socket.assigns.waiting[:task_id] == id,
      do: acknowledge(result, socket),
      else: task_error(socket, id, "invalid_result")
  end

  defp outgoing_task_succeeded(socket, id, _task, result) do
    waiting = socket.assigns.waiting

    if (waiting && waiting[:task_id] == id) and result == %{} do
      send(self(), :outbound_step)

      {:noreply,
       socket
       |> clear_waiting()
       |> assign(:outgoing, %{socket.assigns.outgoing | phase: waiting.next})}
    else
      task_error(socket, id, "invalid_result")
    end
  end

  defp outgoing_task_failed(socket, id, %{operation: "state_query"}, code) do
    descriptor = socket.assigns.query_waiting && socket.assigns.query_waiting.descriptor

    socket =
      assign(socket,
        outgoing_tasks: Map.delete(socket.assigns.outgoing_tasks, id),
        query_waiting: nil
      )

    if descriptor,
      do: defer_checkout(socket, descriptor["note_id"], code),
      else: {:noreply, socket}
  end

  defp outgoing_task_failed(socket, id, %{operation: op}, _code)
       when op in ~w(inventory_complete transfer_abort) do
    socket = assign(socket, :outgoing_tasks, Map.delete(socket.assigns.outgoing_tasks, id))

    if op == "transfer_abort",
      do: recover_outgoing(socket, :remote_task_failed),
      else: {:noreply, socket}
  end

  defp outgoing_task_failed(socket, id, _task, _code) do
    socket = assign(socket, :outgoing_tasks, Map.delete(socket.assigns.outgoing_tasks, id))

    case submit_outgoing_task(socket, "transfer_abort", %{
           "transfer_id" => socket.assigns.outgoing.transfer
         }) do
      {:ok, _, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  defp recover_outgoing(%{assigns: %{outgoing: nil}} = socket, _), do: {:noreply, socket}

  defp recover_outgoing(socket, reason) do
    outgoing = socket.assigns.outgoing
    peer = socket.assigns.session_peer
    socket = clear_waiting(socket)

    task =
      start_task(socket, fn ->
        with :ok <- Transfer.cleanup(outgoing), do: Sync.release_lease(peer, outgoing.lease)
      end)

    {:noreply,
     socket
     |> assign(outgoing: %{outgoing | phase: :recovering}, recovery_task: task)
     |> assign(
       :preparation_retries,
       Map.put(socket.assigns.preparation_retries, outgoing.event["note_id"], %{
         attempts: 1,
         reason: reason,
         retry_at: System.monotonic_time(:millisecond) + @preparation_retry_base
       })
     )}
  end

  defp local_task_failure(socket, operation, reason, context) do
    case operation do
      :manager_page ->
        manager = %{
          socket.assigns.sync_manager
          | state: "failed",
            error: %{"code" => "inventory_page_failed", "retryable" => true}
        }

        {:noreply,
         assign(socket, manager_page_task: nil, sync_manager: manager) |> publish_manager_status()}

      :inventory ->
        {:noreply,
         assign(socket, inventory_task: nil, inventory_done: true) |> schedule_reconciliation()}

      :pending ->
        Process.send_after(self(), :poll_pending, 1_000)
        {:noreply, assign(socket, :pending_task, nil) |> manager_failed(wire_error(reason))}

      :checkout ->
        defer_checkout(assign(socket, :checkout_task, nil), context[:note_id], reason)

      _ ->
        recover_outgoing(socket, reason)
    end
  end

  defp handle_local_task_result(ref, result, socket),
    do: handle_info({:local_result, ref, result}, socket)

  defp select_next(socket) do
    pending = socket.assigns.pending_priority
    queue = socket.assigns.queue
    audit = Enum.find(queue, &(not MapSet.member?(pending, &1)))
    urgent = Enum.find(queue, &MapSet.member?(pending, &1))

    id =
      cond do
        socket.assigns.pending_streak >= 8 and audit -> audit
        urgent -> urgent
        true -> hd(queue)
      end

    streak = if MapSet.member?(pending, id), do: socket.assigns.pending_streak + 1, else: 0

    {id, List.delete(queue, id),
     assign(socket,
       pending_streak: streak,
       pending_priority: MapSet.delete(pending, id)
     )}
  end

  defp join_peer(payload) do
    with %{"node_id" => node_id} <- payload,
         true <- Protocol.uuid?(node_id),
         :ok <- Phoenix.PubSub.subscribe(GSMLG.PubSub, "note_sync:#{node_id}") do
      Sync.join(payload)
    else
      _ -> {:error, :invalid_join}
    end
  end

  defp prepare_outgoing(checkout, socket) do
    event = checkout.event
    bytes = checkout.metadata
    attachments = if event["snapshot"], do: event["snapshot"]["attachments"], else: []
    transfer = Ecto.UUID.generate()
    deadline = commit_deadline(event, byte_size(bytes))

    outgoing = %{
      lease: checkout.lease_id,
      metadata_hash: checkout.metadata_hash,
      event: event,
      objects: checkout.objects,
      transfer: transfer,
      attachments: attachments,
      preparing: attachments,
      prepared: %{},
      directory: Path.join(socket.assigns.staging_root, "outgoing-" <> transfer),
      preparation_started: System.monotonic_time(:millisecond),
      commit_deadline: deadline,
      bytes: bytes,
      file: nil,
      blob: "event",
      offset: 0,
      phase: :prepare
    }

    socket =
      if attachments == [] or task_mode?(socket) do
        socket
      else
        token = make_ref()
        timer = Process.send_after(self(), {:preparation_deadline, token}, deadline)
        assign(socket, :preparation_timer, {token, timer})
      end

    send(self(), :outbound_step)
    {:noreply, assign(socket, :outgoing, outgoing)}
  end

  defp step(%{phase: :prepare, preparing: [attachment | rest]} = outgoing, socket) do
    storage_id = outgoing.objects[attachment["id"]]

    task =
      start_task(
        socket,
        fn -> Outbound.prepare(outgoing.directory, storage_id, attachment) end,
        read_deadline(attachment["size_bytes"])
      )

    {:noreply,
     assign(socket,
       read_task:
         Map.merge(task, %{
           attachment: attachment,
           remaining: rest,
           note_id: outgoing.event["note_id"],
           storage_file_id: storage_id
         }),
       outgoing: %{outgoing | phase: :preparing}
     )}
  end

  defp step(%{phase: :prepare, preparing: []} = outgoing, socket) do
    if socket.assigns.preparation_timer do
      {_token, timer} = socket.assigns.preparation_timer
      cancel_timer(timer)

      GSMLG.Telemetry.info("GaoNote sync attachment preparation finished",
        metadata: %{
          peer_id: socket.assigns.session_peer.id,
          note_id: outgoing.event["note_id"],
          event_id: outgoing.event["event_id"],
          attachment_count: length(outgoing.attachments),
          duration_ms: System.monotonic_time(:millisecond) - outgoing.preparation_started
        }
      )
    end

    outgoing = %{outgoing | phase: :begin}
    step(outgoing, assign(socket, outgoing: outgoing, preparation_timer: nil))
  end

  defp step(%{phase: :begin} = outgoing, socket) do
    request(
      socket,
      "transfer_begin",
      %{
        "transfer_id" => outgoing.transfer,
        "size_bytes" => byte_size(outgoing.bytes),
        "checksum_sha256" => outgoing.metadata_hash
      },
      :chunks
    )
  end

  defp step(%{phase: :chunks, bytes: nil} = outgoing, socket) do
    remaining = outgoing.file.size - outgoing.offset

    if remaining == 0 do
      finish_blob(socket)
    else
      task =
        start_task(socket, fn ->
          Outbound.read_chunk(outgoing.file.path, outgoing.offset, min(remaining, 65_536))
        end)

      {:noreply, assign(socket, chunk_task: task, outgoing: %{outgoing | phase: :reading_chunk})}
    end
  end

  defp step(%{phase: :chunks} = outgoing, socket) do
    remaining = byte_size(outgoing.bytes) - outgoing.offset

    if remaining == 0 do
      finish_blob(socket)
    else
      size = min(remaining, 65_536)

      send_chunk(socket, binary_part(outgoing.bytes, outgoing.offset, size))
    end
  end

  defp step(%{phase: :next_blob, attachments: [attachment | rest]} = outgoing, socket) do
    outgoing = %{
      outgoing
      | attachments: rest,
        bytes: nil,
        file: Map.fetch!(outgoing.prepared, attachment["id"]),
        offset: 0,
        blob: "attachment:" <> attachment["id"]
    }

    request(
      assign(socket, :outgoing, outgoing),
      "attachment_begin",
      %{"transfer_id" => outgoing.transfer, "blob_id" => outgoing.blob},
      :chunks
    )
  end

  defp step(%{phase: :next_blob, attachments: []} = outgoing, socket) do
    request(
      socket,
      "transfer_commit",
      %{"transfer_id" => outgoing.transfer},
      :confirmed,
      outgoing.commit_deadline + @commit_reply_margin
    )
  end

  defp finish_blob(socket) do
    outgoing = socket.assigns.outgoing

    request(
      socket,
      "blob_end",
      %{"transfer_id" => outgoing.transfer, "blob_id" => outgoing.blob},
      :next_blob
    )
  end

  defp send_chunk(socket, bytes) do
    outgoing = socket.assigns.outgoing

    payload = %{
      "transfer_id" => outgoing.transfer,
      "blob_id" => outgoing.blob,
      "offset" => outgoing.offset,
      "data" => Base.encode64(bytes)
    }

    if frame_fits?(socket, "blob_chunk", payload, nil) do
      if task_mode?(socket) do
        {:noreply, socket} = request(socket, "blob_chunk", payload, :chunks)

        waiting =
          Map.put(socket.assigns.waiting, :received_bytes, outgoing.offset + byte_size(bytes))

        {:noreply, assign(socket, :waiting, waiting)}
      else
        push(socket, "blob_chunk", payload)
        Process.send_after(self(), :outbound_step, 1)

        {:noreply,
         assign(socket, :outgoing, %{outgoing | offset: outgoing.offset + byte_size(bytes)})}
      end
    else
      stop(socket)
    end
  end

  defp request(socket, event, payload, next, deadline \\ @deadline) do
    if task_mode?(socket) do
      case submit_outgoing_task(socket, event, payload) do
        {:ok, id, socket} ->
          {:noreply, assign(socket, :waiting, %{task_id: id, next: next, timer: nil})}

        {:error, socket} ->
          {:noreply, socket}
      end
    else
      legacy_request(socket, event, payload, next, deadline)
    end
  end

  defp legacy_request(socket, event, payload, next, deadline) do
    sequence = socket.assigns.sequence + 1
    ref = "sync-#{sequence}"

    if frame_fits?(socket, event, payload, ref) do
      message = %Phoenix.Socket.Message{
        join_ref: socket.join_ref,
        ref: ref,
        topic: socket.topic,
        event: event,
        payload: payload
      }

      send(socket.transport_pid, socket.serializer.encode!(message))
      timer = Process.send_after(self(), {:request_deadline, ref}, deadline)

      {:noreply,
       assign(socket, sequence: sequence, waiting: %{ref: ref, next: next, timer: timer})}
    else
      stop(socket)
    end
  end

  defp frame_fits?(socket, event, payload, ref) do
    # Phoenix.ChannelTest uses references; real websocket refs are JSON strings.
    ref = if is_reference(ref), do: inspect(ref), else: ref
    byte_size(Jason.encode!([socket.join_ref, ref, socket.topic, event, payload])) <= 131_072
  end

  defp acknowledge(
         payload,
         %{assigns: %{outgoing: outgoing, waiting: %{next: :confirmed}, confirmation_task: nil}} =
           socket
       )
       when not is_nil(outgoing) do
    if payload == Protocol.ack(outgoing.event) do
      peer = socket.assigns.session_peer

      task =
        start_task(socket, fn ->
          with :ok <- Sync.ack(peer, payload, outgoing.lease), do: Transfer.cleanup(outgoing)
        end)

      {:noreply, socket |> clear_waiting() |> assign(:confirmation_task, task)}
    else
      {:noreply, socket}
    end
  end

  defp acknowledge(_payload, socket), do: {:noreply, socket}

  defp reject(
         payload,
         %{assigns: %{outgoing: outgoing, waiting: %{next: :confirmed}, confirmation_task: nil}} =
           socket
       )
       when not is_nil(outgoing) do
    if Protocol.exact_keys?(payload, ~w(code event_id note_id reason)) and
         payload["code"] == "note_rejected" and
         payload["event_id"] == outgoing.event["event_id"] and
         payload["note_id"] == outgoing.event["note_id"] and
         payload["reason"] in ["validation_failed", "catalog_conflict"] do
      peer = socket.assigns.session_peer

      task =
        start_task(socket, fn ->
          with :ok <- Sync.reject(peer, payload, outgoing.lease), do: Transfer.cleanup(outgoing)
        end)

      {:noreply, socket |> clear_waiting() |> assign(:confirmation_task, task)}
    else
      {:noreply, socket}
    end
  end

  defp reject(_payload, socket), do: {:noreply, socket}

  defp next_note(socket) do
    send(self(), :send_next)

    {:noreply,
     socket
     |> manager_progress()
     |> clear_preparation_retry(socket.assigns.outgoing.event["note_id"])
     |> clear_waiting()
     |> assign(
       outgoing: nil,
       pending_priority:
         MapSet.delete(
           socket.assigns.pending_priority,
           socket.assigns.outgoing.event["note_id"]
         )
     )}
  end

  defp enqueue(socket, ids, pending \\ false) do
    active = [
      get_in(socket.assigns, [:outgoing, :event, "note_id"]),
      get_in(socket.assigns, [:checkout_task, :note_id]),
      get_in(socket.assigns, [:query_waiting, :descriptor, "note_id"])
    ]

    # Newer changes remain durable and are picked up by the next poll after ACK.
    queue =
      Enum.uniq(socket.assigns.queue ++ ids)
      |> Enum.reject(&(&1 in active or preparation_deferred?(socket, &1)))

    priorities = socket.assigns[:pending_priority] || MapSet.new()

    priorities =
      if pending, do: Enum.reduce(ids, priorities, &MapSet.put(&2, &1)), else: priorities

    assign(socket, queue: queue, pending_priority: priorities)
  end

  # Checkout has rolled back before returning a source preparation error, so no
  # transfer was announced and no lease needs an uncertain commit resolution.
  defp defer_checkout(socket, id, reason) do
    previous = socket.assigns.preparation_retries[id]
    attempts = if previous, do: previous.attempts + 1, else: 1
    delay = min(@preparation_retry_max, @preparation_retry_base * 2 ** min(attempts - 1, 6))

    retry = %{
      attempts: attempts,
      reason: failure_reason(reason),
      retry_at: System.monotonic_time(:millisecond) + delay
    }

    log_failure(socket, :checkout, reason, %{note_id: id}, %{
      failure_scope: :note,
      retry_in_ms: delay,
      attempt: attempts
    })

    send(self(), :send_next)

    {:noreply,
     assign(socket, preparation_retries: Map.put(socket.assigns.preparation_retries, id, retry))}
  end

  defp preparation_deferred?(socket, id) do
    case (socket.assigns[:preparation_retries] || %{})[id] do
      %{retry_at: retry_at} -> retry_at > System.monotonic_time(:millisecond)
      nil -> false
    end
  end

  defp clear_preparation_retry(socket, id),
    do: assign(socket, :preparation_retries, Map.delete(socket.assigns.preparation_retries, id))

  # No frame has been announced in these phases, so only this note needs resetting.
  defp preparation_failure(socket, operation, reason, context \\ %{})

  defp preparation_failure(
         %{assigns: %{outgoing: %{phase: phase} = outgoing, waiting: nil}} = socket,
         operation,
         reason,
         context
       )
       when phase in [:prepare, :preparing] do
    if socket.assigns.preparation_timer do
      {_token, timer} = socket.assigns.preparation_timer
      cancel_timer(timer)
    end

    read_task = socket.assigns.read_task

    if read_task do
      cancel_timer(read_task.timer)
      Process.demonitor(read_task.ref, [:flush])
    end

    peer = socket.assigns.session_peer
    guard = socket.assigns.guard
    note_id = outgoing.event["note_id"]
    previous = socket.assigns.preparation_retries[note_id]
    attempts = if previous, do: previous.attempts + 1, else: 1
    delay = min(@preparation_retry_max, @preparation_retry_base * 2 ** min(attempts - 1, 6))

    retry = %{
      attempts: attempts,
      reason: failure_reason(reason),
      retry_at: System.monotonic_time(:millisecond) + delay
    }

    log_failure(socket, operation, reason, context, %{
      failure_scope: :note,
      retry_in_ms: delay,
      attempt: attempts
    })

    task =
      start_task(socket, fn ->
        # Keep the original writer guard-owned until it is known to be dead.
        if read_task do
          monitor = Process.monitor(read_task.pid)
          Process.exit(read_task.pid, :kill)

          receive do
            {:DOWN, ^monitor, :process, _pid, _reason} -> :ok
          end

          send(guard, {:task_done, read_task.pid})
        end

        with :ok <- Transfer.cleanup(outgoing), do: Sync.release_lease(peer, outgoing.lease)
      end)

    {:noreply,
     assign(socket,
       outgoing: %{outgoing | phase: :recovering},
       read_task: nil,
       preparation_timer: nil,
       recovery_task: Map.put(task, :note_id, note_id),
       preparation_retries: Map.put(socket.assigns.preparation_retries, note_id, retry),
       queue: Enum.reject(socket.assigns.queue, &(&1 == note_id))
     )}
  end

  defp preparation_failure(socket, operation, reason, context),
    do: fail(socket, operation, reason, context)

  defp clear_waiting(%{assigns: %{waiting: %{timer: timer}}} = socket) do
    cancel_timer(timer)
    assign(socket, :waiting, nil)
  end

  defp clear_waiting(socket), do: assign(socket, :waiting, nil)

  defp reply_ref(%{ref: nil}), do: nil
  defp reply_ref(socket), do: socket_ref(socket)

  defp active_task(socket, ref) do
    Enum.find_value(@task_operations, fn {key, operation} ->
      case socket.assigns[key] do
        %{ref: ^ref} = task -> {operation, task}
        _ -> nil
      end
    end)
  end

  # Session tasks can wait behind apply/query locks. Grant one extension;
  # later work or stale deadline messages must not keep the task alive forever.
  defp session_task_deadline(socket, operation, %{session_deadline_deferred: true} = task) do
    if Process.read_timer(task.timer),
      do: {:noreply, socket},
      else: fail(socket, operation, :task_timeout, task)
  end

  defp session_task_deadline(socket, operation, task) do
    remaining =
      Enum.reduce([:apply_task, :query_task], 0, fn key, longest ->
        case socket.assigns[key] do
          %{timer: timer} -> max(Process.read_timer(timer) || 0, longest)
          _ -> longest
        end
      end)

    if remaining > 0 do
      cancel_timer(task.timer)
      timer = Process.send_after(self(), {:task_deadline, task.ref}, remaining + @deadline)
      deferred = Map.merge(task, %{timer: timer, session_deadline_deferred: true})
      {key, ^operation} = List.keyfind(@task_operations, operation, 1)
      {:noreply, assign(socket, key, deferred)}
    else
      fail(socket, operation, :task_timeout, task)
    end
  end

  # Match Agent Note's commit work budget. The sender grants another 30 seconds
  # for delivery of the durable ACK; ordinary requests retain their short limit.
  defp commit_deadline(event, metadata_size) when is_map(event) do
    attachments = (event["snapshot"] || %{})["attachments"] || []
    total = Enum.reduce(attachments, metadata_size, &(&1["size_bytes"] + &2))
    mib = div(total + 1_048_575, 1_048_576)
    min(900_000, 60_000 + mib * 2_000 + length(attachments) * 5_000)
  end

  defp commit_deadline(nil, _metadata_size), do: @deadline

  # Budget connection latency plus one second per MiB, bounded by the 512 MiB
  # blob limit. Pending polls keep renewing the lease during the read.
  defp read_deadline(size) do
    seconds = div(size + @read_bytes_per_second - 1, @read_bytes_per_second)
    @read_base_deadline + seconds * 1_000
  end

  defp start_task(socket, work, deadline \\ @deadline, durable \\ false) do
    owner = self()

    task =
      Task.Supervisor.async_nolink(GSMLG.TaskSupervisor, fn ->
        owner_ref = Process.monitor(owner)

        receive do
          :begin_work ->
            Process.demonitor(owner_ref, [:flush])
            work.()

          {:DOWN, ^owner_ref, :process, _pid, _reason} ->
            {:error, :owner_gone}
        end
      end)

    send(socket.assigns.guard, {:task, task.pid, durable})
    send(task.pid, :begin_work)

    timer =
      if task_mode?(socket),
        do: nil,
        else: Process.send_after(self(), {:task_deadline, task.ref}, deadline)

    %{ref: task.ref, pid: task.pid, timer: timer}
  end

  defp finish_task(socket, task) do
    Process.demonitor(task.ref, [:flush])
    cancel_timer(task.timer)
    send(socket.assigns.guard, {:task_done, task.pid})
  end

  defp touch_incoming(socket) do
    cancel_incoming_timer(socket)
    token = make_ref()

    if task_mode?(socket) do
      assign(socket, :incoming_timer, nil)
    else
      timer = Process.send_after(self(), {:incoming_deadline, token}, @deadline)
      assign(socket, :incoming_timer, {token, timer})
    end
  end

  defp cancel_incoming_timer(%{assigns: %{incoming_timer: {_token, timer}}}),
    do: cancel_timer(timer)

  defp cancel_incoming_timer(_socket), do: :ok

  defp fail(socket, operation, reason, context \\ %{}) do
    log_failure(socket, operation, reason, context)

    if task_mode?(socket),
      do: local_task_failure(socket, operation, reason, context),
      else: stop(socket)
  end

  defp log_failure(socket, operation, reason, context, extra \\ %{}) do
    note_id =
      context[:note_id] || get_in(socket.assigns, [:outgoing, :event, "note_id"]) ||
        get_in(socket.assigns, [:incoming, :event, "note_id"])

    metadata =
      %{
        operation: operation,
        reason: failure_reason(reason),
        failure_type: context[:failure_type],
        peer_id: socket.assigns.session_peer.id,
        note_id: diagnostic_id(note_id),
        storage_file_id: diagnostic_id(context[:storage_file_id])
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(extra)

    GSMLG.Telemetry.error("GaoNote sync operation failed", metadata: metadata)
  end

  defp diagnostic_id(value), do: if(Protocol.uuid?(value), do: value)

  defp failure_reason(reason) when is_atom(reason), do: reason
  defp failure_reason(%{__struct__: module}) when is_atom(module), do: module

  defp failure_reason(reason) when is_tuple(reason) and tuple_size(reason) > 0,
    do: failure_reason(elem(reason, 0))

  defp failure_reason(_reason), do: :unspecified_error

  defp cancel_timer(nil), do: false
  defp cancel_timer(timer), do: Process.cancel_timer(timer)

  defp stop(socket), do: {:stop, {:shutdown, :sync_session_error}, socket}

  # The monitor also runs after untrappable channel exits; a session token ensures
  # an old connection cannot release a replacement connection's durable leases.
  defp monitor(owner, peer, directories) do
    ref = Process.monitor(owner)
    monitor_loop(ref, peer, directories, [])
  end

  defp monitor_loop(ref, peer, directories, tasks) do
    receive do
      {:task, pid, durable} ->
        monitor_loop(ref, peer, directories, [{pid, durable} | tasks])

      {:task_done, pid} ->
        monitor_loop(
          ref,
          peer,
          directories,
          Enum.reject(tasks, fn {owned, _} -> owned == pid end)
        )

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Enum.each(tasks, fn {pid, durable} ->
          unless durable, do: Task.Supervisor.terminate_child(GSMLG.TaskSupervisor, pid)
        end)

        Enum.each(tasks, fn {pid, durable} ->
          if durable do
            task_ref = Process.monitor(pid)

            receive do
              {:DOWN, ^task_ref, :process, ^pid, _} -> :ok
            end
          end
        end)

        Enum.each(directories, &Transfer.cleanup(%{directory: &1}))
        Sync.release_session(peer)
    end
  end
end
