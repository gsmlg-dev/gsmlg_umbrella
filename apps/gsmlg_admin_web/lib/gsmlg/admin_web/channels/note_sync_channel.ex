defmodule GSMLG.AdminWeb.NoteSyncChannel do
  @moduledoc "Duplex sync transport; outbound requests advance one frame at a time."
  use Phoenix.Channel
  alias GSMLG.GaoNote.Sync
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
          sequence: 0
        )

      {:ok, Map.put(response, "capabilities", ["state_query_v1"]), socket}
    else
      _ -> {:error, %{code: "invalid_join"}}
    end
  end

  @impl true
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
        commit_deadline(incoming.event, incoming.event_size)
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
      Process.cancel_timer(waiting.timer)
      [remote] = payload["response"]["items"]

      checkout_note(
        assign(socket, :query_waiting, nil),
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

  def handle_info(:send_next, %{assigns: %{inventory_started: false}} = socket),
    do: {:noreply, socket}

  def handle_info(
        :send_next,
        %{assigns: %{capabilities: ["state_query_v1"], inventory_task: task}} = socket
      )
      when not is_nil(task),
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
        %{unclassified: true} when socket.assigns.capabilities == ["state_query_v1"] ->
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

        %{descriptor: descriptor} when socket.assigns.capabilities == ["state_query_v1"] ->
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

    push(socket, "inventory_complete", payload)
    {:noreply, socket |> assign(:inventory_done, true) |> schedule_reconciliation()}
  end

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
    if socket.assigns.reconcile_timer, do: Process.cancel_timer(socket.assigns.reconcile_timer)
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
    task = start_task(socket, fn -> Sync.pending_ids(peer) end)
    {:noreply, assign(socket, :pending_task, task)}
  end

  def handle_info(:poll_pending, socket), do: {:noreply, socket}

  def handle_info({ref, result}, %{assigns: %{query_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{inventory_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{pending_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :pending_task, nil)

    case result do
      {:ok, :busy} ->
        Process.send_after(self(), :poll_pending, 1_000)
        {:noreply, socket}

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

  def handle_info({ref, result}, %{assigns: %{blob_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{confirmation_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :confirmation_task, nil)

    case result do
      :ok -> next_note(socket)
      {:error, reason} -> fail(socket, :confirmation, reason)
    end
  end

  def handle_info({ref, result}, %{assigns: %{checkout_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{apply_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{read_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{recovery_task: %{ref: ref} = task}} = socket) do
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

  def handle_info({ref, result}, %{assigns: %{chunk_task: %{ref: ref} = task}} = socket) do
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
    case active_task(socket, ref) do
      {:read, task} ->
        preparation_failure(socket, :read, reason, Map.put(task, :failure_type, :task_exit))

      {operation, task} ->
        fail(socket, operation, reason, Map.put(task, :failure_type, :task_exit))

      nil ->
        {:noreply, socket}
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
  def handle_info({ref, _result}, socket) when is_reference(ref), do: {:noreply, socket}

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
    if socket.assigns.reconcile_timer, do: Process.cancel_timer(socket.assigns.reconcile_timer)
    assign(socket, :reconcile_timer, Process.send_after(self(), :reconcile_inventory, 60_000))
  end

  defp negotiated?(socket), do: socket.assigns.capabilities == ["state_query_v1"]

  defp query_note(socket, descriptor) do
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
      if attachments == [] do
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
      Process.cancel_timer(timer)

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
      push(socket, "blob_chunk", payload)
      Process.send_after(self(), :outbound_step, 1)

      {:noreply,
       assign(socket, :outgoing, %{outgoing | offset: outgoing.offset + byte_size(bytes)})}
    else
      stop(socket)
    end
  end

  defp request(socket, event, payload, next, deadline \\ @deadline) do
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
      Process.cancel_timer(timer)
    end

    read_task = socket.assigns.read_task

    if read_task do
      Process.cancel_timer(read_task.timer)
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
    Process.cancel_timer(timer)
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
      Process.cancel_timer(task.timer)
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

  defp start_task(socket, work, deadline \\ @deadline) do
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

    send(socket.assigns.guard, {:task, task.pid})
    send(task.pid, :begin_work)
    timer = Process.send_after(self(), {:task_deadline, task.ref}, deadline)
    %{ref: task.ref, pid: task.pid, timer: timer}
  end

  defp finish_task(socket, task) do
    Process.demonitor(task.ref, [:flush])
    Process.cancel_timer(task.timer)
    send(socket.assigns.guard, {:task_done, task.pid})
  end

  defp touch_incoming(socket) do
    cancel_incoming_timer(socket)
    token = make_ref()
    timer = Process.send_after(self(), {:incoming_deadline, token}, @deadline)
    assign(socket, :incoming_timer, {token, timer})
  end

  defp cancel_incoming_timer(%{assigns: %{incoming_timer: {_token, timer}}}),
    do: Process.cancel_timer(timer)

  defp cancel_incoming_timer(_socket), do: :ok

  defp fail(socket, operation, reason, context \\ %{}) do
    log_failure(socket, operation, reason, context)
    stop(socket)
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

  defp stop(socket), do: {:stop, {:shutdown, :sync_session_error}, socket}

  # The monitor also runs after untrappable channel exits; a session token ensures
  # an old connection cannot release a replacement connection's durable leases.
  defp monitor(owner, peer, directories) do
    ref = Process.monitor(owner)
    monitor_loop(ref, peer, directories, [])
  end

  defp monitor_loop(ref, peer, directories, tasks) do
    receive do
      {:task, pid} ->
        monitor_loop(ref, peer, directories, [pid | tasks])

      {:task_done, pid} ->
        monitor_loop(ref, peer, directories, List.delete(tasks, pid))

      {:DOWN, ^ref, :process, _pid, _reason} ->
        Enum.each(tasks, &Task.Supervisor.terminate_child(GSMLG.TaskSupervisor, &1))
        Enum.each(directories, &Transfer.cleanup(%{directory: &1}))
        Sync.release_session(peer)
    end
  end
end
