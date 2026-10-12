defmodule GSMLG.AdminWeb.NoteSyncChannel do
  @moduledoc "Duplex sync transport; outbound requests advance one frame at a time."
  use Phoenix.Channel
  alias GSMLG.GaoNote.Sync
  alias GSMLG.GaoNote.Sync.{Protocol, Snapshot, Transfer}
  @deadline 10_000
  @task_keys ~w(inventory_task pending_task blob_task confirmation_task checkout_task read_task apply_task)a

  @impl true
  def join("note_sync:v1", payload, socket) do
    with {:ok, %{peer: peer, response: response}} <- Sync.join(socket.assigns.sync_peer, payload) do
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
          pending_task: nil,
          blob_task: nil,
          confirmation_task: nil,
          apply_task: nil,
          checkout_task: nil,
          read_task: nil,
          outgoing: nil,
          waiting: nil,
          queue: [],
          inventory_started: false,
          inventory_done: false,
          sequence: 0
        )

      {:ok, response, socket}
    else
      _ -> {:error, %{code: "unauthorized"}}
    end
  end

  @impl true
  def handle_in("inventory_start", payload, socket) when map_size(payload) == 0 do
    if socket.assigns.inventory_started do
      {:reply, {:ok, %{}}, socket}
    else
      peer = socket.assigns.session_peer
      task = start_task(socket, fn -> Sync.inventory(peer) end)

      {:noreply,
       assign(socket,
         inventory_started: true,
         inventory_task: Map.put(task, :reply_to, reply_ref(socket))
       )}
    end
  end

  def handle_in("inventory_complete", payload, socket) when map_size(payload) == 0,
    do: {:reply, {:ok, %{}}, socket}

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
      start_task(socket, fn ->
        with {:ok, event, objects} <- Transfer.commit(incoming, payload),
             do: Sync.apply(peer, event, objects)
      end)

    reply_to = reply_ref(socket)
    cancel_incoming_timer(socket)

    {:noreply,
     assign(socket, incoming_timer: nil, apply_task: Map.put(task, :reply_to, reply_to))}
  end

  def handle_in("ack", payload, socket), do: acknowledge(payload, socket)
  def handle_in("note_rejected", payload, socket), do: reject(payload, socket)

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
          assign(socket, waiting: nil, outgoing: %{socket.assigns.outgoing | phase: waiting.next})

        send(self(), :outbound_step)
        {:noreply, socket}

      true ->
        stop(socket)
    end
  end

  def handle_in("phx_reply", _payload, socket), do: {:noreply, socket}
  def handle_in(_event, _payload, socket), do: stop(socket)

  @impl true
  def handle_info(
        :send_next,
        %{assigns: %{outgoing: nil, checkout_task: nil, queue: [id | rest]}} = socket
      ) do
    peer = socket.assigns.session_peer
    limit = socket.assigns.limit

    task =
      start_task(socket, fn ->
        case Sync.checkout(peer, id) do
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

    {:noreply, assign(socket, queue: rest, checkout_task: task)}
  end

  def handle_info(
        :send_next,
        %{
          assigns: %{
            outgoing: nil,
            checkout_task: nil,
            inventory_task: nil,
            queue: [],
            inventory_started: true,
            inventory_done: false
          }
        } =
          socket
      ) do
    push(socket, "inventory_complete", %{})
    {:noreply, assign(socket, :inventory_done, true)}
  end

  def handle_info(:send_next, socket), do: {:noreply, socket}

  def handle_info(:poll_pending, %{assigns: %{pending_task: nil}} = socket) do
    peer = socket.assigns.session_peer
    task = start_task(socket, fn -> Sync.pending_ids(peer) end)
    {:noreply, assign(socket, :pending_task, task)}
  end

  def handle_info(:poll_pending, socket), do: {:noreply, socket}

  def handle_info({ref, result}, %{assigns: %{inventory_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :inventory_task, nil)

    case result do
      {:ok, ids} ->
        if task.reply_to, do: reply(task.reply_to, {:ok, %{}})
        send(self(), :send_next)
        {:noreply, assign(socket, :queue, Enum.uniq(socket.assigns.queue ++ ids))}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{pending_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :pending_task, nil)

    case result do
      {:ok, ids} ->
        Process.send_after(self(), :poll_pending, 1_000)
        send(self(), :send_next)
        {:noreply, assign(socket, :queue, Enum.uniq(socket.assigns.queue ++ ids))}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{blob_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :blob_task, nil)

    case result do
      {:ok, transfer} ->
        if task.reply_to, do: reply(task.reply_to, {:ok, %{}})
        {:noreply, socket |> assign(:incoming, transfer) |> touch_incoming()}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{confirmation_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :confirmation_task, nil)

    case result do
      :ok -> next_note(socket)
      {:error, _} -> stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{checkout_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :checkout_task, nil)

    case result do
      {:ok, checkout} ->
        prepare_outgoing(checkout, socket)

      :empty ->
        send(self(), :send_next)
        {:noreply, socket}

      {:error, :too_large} ->
        send(self(), :send_next)
        {:noreply, socket}

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{apply_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    incoming = socket.assigns.incoming
    cleanup = Transfer.cleanup(incoming)
    socket = assign(socket, incoming: nil, apply_task: nil)
    result = if cleanup == :ok, do: result, else: cleanup

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

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({ref, result}, %{assigns: %{read_task: %{ref: ref} = task}} = socket) do
    finish_task(socket, task)
    socket = assign(socket, :read_task, nil)

    case result do
      {:ok, bytes} ->
        outgoing = %{
          socket.assigns.outgoing
          | attachments: task.remaining,
            bytes: bytes,
            offset: 0,
            blob: "attachment:" <> task.attachment["id"]
        }

        request(
          assign(socket, :outgoing, outgoing),
          "attachment_begin",
          %{"transfer_id" => outgoing.transfer, "blob_id" => outgoing.blob},
          :chunks
        )

      {:error, _} ->
        stop(socket)
    end
  end

  def handle_info({:task_deadline, ref}, socket) do
    if active_task?(socket, ref), do: stop(socket), else: {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    if active_task?(socket, ref), do: stop(socket), else: {:noreply, socket}
  end

  def handle_info(:outbound_step, %{assigns: %{outgoing: outgoing, waiting: nil}} = socket)
      when not is_nil(outgoing),
      do: step(outgoing, socket)

  def handle_info(:outbound_step, socket), do: {:noreply, socket}

  def handle_info({:request_deadline, ref}, %{assigns: %{waiting: %{ref: ref}}} = socket),
    do: stop(socket)

  def handle_info(
        {:incoming_deadline, token},
        %{assigns: %{incoming_timer: {token, _timer}}} = socket
      ),
      do: stop(socket)

  def handle_info({:request_deadline, _}, socket), do: {:noreply, socket}
  def handle_info({:incoming_deadline, _}, socket), do: {:noreply, socket}

  defp prepare_outgoing(checkout, socket) do
    event = checkout.event
    bytes = checkout.metadata
    attachments = if event["snapshot"], do: event["snapshot"]["attachments"], else: []

    outgoing = %{
      lease: checkout.lease_id,
      metadata_hash: checkout.metadata_hash,
      event: event,
      objects: checkout.objects,
      transfer: Ecto.UUID.generate(),
      attachments: attachments,
      bytes: bytes,
      blob: "event",
      offset: 0,
      phase: :begin
    }

    send(self(), :outbound_step)
    {:noreply, assign(socket, :outgoing, outgoing)}
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

  defp step(%{phase: :chunks} = outgoing, socket) do
    remaining = byte_size(outgoing.bytes) - outgoing.offset

    if remaining == 0 do
      request(
        socket,
        "blob_end",
        %{"transfer_id" => outgoing.transfer, "blob_id" => outgoing.blob},
        :next_blob
      )
    else
      size = min(remaining, 65_536)

      payload = %{
        "transfer_id" => outgoing.transfer,
        "blob_id" => outgoing.blob,
        "offset" => outgoing.offset,
        "data" => Base.encode64(binary_part(outgoing.bytes, outgoing.offset, size))
      }

      if frame_fits?(socket, "blob_chunk", payload, nil) do
        push(socket, "blob_chunk", payload)
        Process.send_after(self(), :outbound_step, 1)
        {:noreply, assign(socket, :outgoing, %{outgoing | offset: outgoing.offset + size})}
      else
        stop(socket)
      end
    end
  end

  defp step(%{phase: :next_blob, attachments: [attachment | rest]} = outgoing, socket) do
    task =
      start_task(socket, fn ->
        with storage_id when not is_nil(storage_id) <- outgoing.objects[attachment["id"]],
             {:ok, bytes} <- Snapshot.read_object(storage_id),
             true <-
               byte_size(bytes) == attachment["size_bytes"] and
                 Protocol.sha256(bytes) == attachment["checksum_sha256"] do
          {:ok, bytes}
        else
          _ -> {:error, :object_read_failed}
        end
      end)

    {:noreply,
     assign(socket,
       read_task: Map.merge(task, %{attachment: attachment, remaining: rest}),
       outgoing: %{outgoing | phase: :reading}
     )}
  end

  defp step(%{phase: :next_blob, attachments: []} = outgoing, socket),
    do: request(socket, "transfer_commit", %{"transfer_id" => outgoing.transfer}, :confirmed)

  defp request(socket, event, payload, next) do
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
      Process.send_after(self(), {:request_deadline, ref}, @deadline)
      {:noreply, assign(socket, sequence: sequence, waiting: %{ref: ref, next: next})}
    else
      stop(socket)
    end
  end

  defp frame_fits?(socket, event, payload, ref),
    do: byte_size(Jason.encode!([socket.join_ref, ref, socket.topic, event, payload])) <= 131_072

  defp acknowledge(
         payload,
         %{assigns: %{outgoing: outgoing, waiting: %{next: :confirmed}, confirmation_task: nil}} =
           socket
       )
       when not is_nil(outgoing) do
    if payload == Protocol.ack(outgoing.event) do
      peer = socket.assigns.session_peer
      task = start_task(socket, fn -> Sync.ack(peer, payload, outgoing.lease) end)
      {:noreply, assign(socket, confirmation_task: task, waiting: nil)}
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
      task = start_task(socket, fn -> Sync.reject(peer, payload, outgoing.lease) end)
      {:noreply, assign(socket, confirmation_task: task, waiting: nil)}
    else
      {:noreply, socket}
    end
  end

  defp reject(_payload, socket), do: {:noreply, socket}

  defp next_note(socket) do
    send(self(), :send_next)
    {:noreply, assign(socket, outgoing: nil, waiting: nil)}
  end

  defp reply_ref(%{ref: nil}), do: nil
  defp reply_ref(socket), do: socket_ref(socket)

  defp active_task?(socket, ref) do
    Enum.any?(@task_keys, fn key -> match?(%{ref: ^ref}, socket.assigns[key]) end)
  end

  defp start_task(socket, work) do
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
    timer = Process.send_after(self(), {:task_deadline, task.ref}, @deadline)
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
