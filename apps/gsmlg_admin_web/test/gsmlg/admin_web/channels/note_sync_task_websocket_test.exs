defmodule GSMLG.AdminWeb.NoteSyncTaskWebSocketTest do
  use GSMLG.AdminWeb.NoteSyncAutoCase, async: false
  import Bitwise
  alias GSMLG.GaoNote.Compat

  setup do
    listener =
      start_supervised!({Bandit, plug: GSMLG.AdminWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {{127, 0, 0, 1}, port}} = ThousandIsland.listener_info(listener)

    %{
      peer: %{id: Ecto.UUID.generate()},
      port: port,
      headers: [],
      endpoint: GSMLG.AdminWeb.Endpoint,
      socket_module: GSMLG.AdminWeb.NoteSyncSocket
    }
  end

  @tag task_inventory: true
  test "one actual websocket heartbeats while inventory is blocked beyond ten seconds", context do
    {:ok, note} =
      Compat.save_note(
        %{title: "slow inventory", content: "checking", labels: [[context.label, "selected"]]},
        nil
      )

    {tcp, response} = open(context.port, context.headers)
    assert response =~ "101 Switching Protocols"

    hello = %{
      "protocol_version" => 1,
      "node_id" => context.peer.id,
      "selectors" => [context.label <> "=selected"],
      "max_blob_bytes" => 536_870_912
    }

    send_frame(tcp, ["join", "join", "note_sync:v1", "phx_join", hello])
    assert ["join", "join", "note_sync:v1", "phx_reply", %{"status" => "ok"}] = receive_frame(tcp)
    caps = %{"capabilities" => ["state_query_v1", "task_sync_v1"]}
    send_frame(tcp, ["join", "caps", "note_sync:v1", "sync_negotiate", caps])

    assert ["join", "caps", "note_sync:v1", "phx_reply", %{"status" => "ok", "response" => ^caps}] =
             receive_frame(tcp)

    guard = session_guard(context)
    owner = self()
    handler = {__MODULE__, make_ref()}
    peer_id = Ecto.UUID.dump!(context.peer.id)
    held = :atomics.new(1, [])

    :telemetry.attach(
      handler,
      [:gsmlg, :repo, :query],
      fn _, _, metadata, _ ->
        if String.contains?(metadata.query, ") cohort") and
             peer_id in metadata.params and :atomics.compare_exchange(held, 1, 0, 1) == :ok do
          send(owner, {:inventory_locked, self()})

          receive do
            :release_inventory -> :ok
          after
            30_000 -> raise "inventory barrier timed out"
          end
        end
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach(handler)
      :gen_tcp.close(tcp)
      monitor = Process.monitor(guard)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5_000
    end)

    id = "#{context.peer.id}:1"

    send_frame(tcp, [
      "join",
      nil,
      "note_sync:v1",
      "task_submit",
      %{"task_id" => id, "operation" => "inventory_start", "payload" => %{}}
    ])

    assert ["join", nil, "note_sync:v1", "task_status", %{"task_id" => ^id, "state" => "queued"}] =
             receive_frame(tcp)

    assert_receive {:inventory_locked, worker}, 2_000

    try do
      assert [
               "join",
               nil,
               "note_sync:v1",
               "task_status",
               %{"task_id" => ^id, "state" => "running"}
             ] = receive_frame(tcp)

      {channel, state} = session_channel(context)
      last_progress = state.assigns.sync_manager.last_progress_at
      Process.sleep(10_100)
      send_frame(tcp, [nil, "healthy", "phoenix", "heartbeat", %{}])

      assert [nil, "healthy", "phoenix", "phx_reply", %{"status" => "ok"}] =
               task_frame_until(tcp, "phx_reply", fn frame -> Enum.at(frame, 1) == "healthy" end)

      assert Process.alive?(worker)
      assert :sys.get_state(channel).assigns.sync_manager.last_progress_at == last_progress
      send_frame(tcp, ["join", nil, "note_sync:v1", "task_get", %{"task_id" => id}])

      assert [
               "join",
               nil,
               "note_sync:v1",
               "task_status",
               %{"task_id" => ^id, "state" => "running"}
             ] =
               task_frame_until(tcp, "task_status", fn frame ->
                 get_in(Enum.at(frame, 4), ["task_id"]) == id
               end)

      send(worker, :release_inventory)

      assert [
               "join",
               nil,
               "note_sync:v1",
               "task_status",
               %{
                 "task_id" => ^id,
                 "state" => "succeeded",
                 "progress" => %{"notes_scanned" => 1, "total_notes" => 1}
               }
             ] =
               task_frame_until(tcp, "task_status", fn frame ->
                 get_in(Enum.at(frame, 4), ["state"]) == "succeeded"
               end)

      assert [
               "join",
               nil,
               "note_sync:v1",
               "task_submit",
               %{"operation" => "state_query", "payload" => query}
             ] =
               task_frame_until(tcp, "task_submit", fn frame ->
                 get_in(Enum.at(frame, 4), ["operation"]) == "state_query"
               end)

      assert hd(query["items"])["note_id"] == note.id
      send_frame(tcp, [nil, "still-healthy", "phoenix", "heartbeat", %{}])

      assert [nil, "still-healthy", "phoenix", "phx_reply", %{"status" => "ok"}] =
               task_frame_until(tcp, "phx_reply", fn frame ->
                 Enum.at(frame, 1) == "still-healthy"
               end)
    after
      send(worker, :release_inventory)
      monitor = Process.monitor(guard)
      :gen_tcp.close(tcp)
      assert_receive {:DOWN, ^monitor, :process, ^guard, _}, 5_000
    end
  end

  defp task_frame_until(tcp, event, predicate) do
    frame = receive_frame(tcp)

    if Enum.at(frame, 3) == event and predicate.(frame),
      do: frame,
      else: task_frame_until(tcp, event, predicate)
  end

  defp session_guard(context) do
    {_channel, socket} = session_channel(context)
    socket.assigns.guard
  end

  defp session_channel(context) do
    peer_id = context.peer.id
    table = context.endpoint.config({:socket, context.socket_module})

    channels =
      table
      |> :ets.tab2list()
      |> Enum.filter(fn {key, _pid} -> is_integer(key) end)
      |> Enum.flat_map(fn {_index, supervisor} ->
        DynamicSupervisor.which_children(supervisor)
      end)
      |> Enum.flat_map(fn {_id, pid, _type, _modules} ->
        case :sys.get_state(pid) do
          %Phoenix.Socket{assigns: %{session_peer: %{id: ^peer_id}}} = socket -> [{pid, socket}]
          _ -> []
        end
      end)

    assert [channel] = channels
    channel
  end

  defp open(port, headers) do
    {:ok, tcp} =
      :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, packet: :raw], 2000)

    on_exit(fn -> :gen_tcp.close(tcp) end)
    fields = Enum.map(headers, fn {key, value} -> "#{key}: #{value}\r\n" end)

    :ok =
      :gen_tcp.send(tcp, [
        "GET /note-sync/websocket?vsn=2.0.0 HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n",
        fields,
        "\r\n"
      ])

    {tcp, receive_headers(tcp, "")}
  end

  defp receive_headers(tcp, collected) do
    if String.contains?(collected, "\r\n\r\n") do
      collected
    else
      {:ok, bytes} = :gen_tcp.recv(tcp, 0, 2000)
      receive_headers(tcp, collected <> bytes)
    end
  end

  defp send_frame(tcp, frame) do
    bytes = Jason.encode!(frame)
    mask = <<1, 2, 3, 4>>

    masked =
      for <<byte <- bytes>>, reduce: {[], 0} do
        {result, index} -> {[bxor(byte, :binary.at(mask, rem(index, 4))) | result], index + 1}
      end
      |> elem(0)
      |> Enum.reverse()
      |> :binary.list_to_bin()

    header =
      if byte_size(bytes) < 126,
        do: <<0x81, 0x80 + byte_size(bytes)>>,
        else: <<0x81, 0xFE, byte_size(bytes)::16>>

    :ok = :gen_tcp.send(tcp, [header, mask, masked])
  end

  defp receive_frame(tcp) do
    {:ok, <<0x81, length>>} = :gen_tcp.recv(tcp, 2, 2000)

    size =
      case length do
        126 ->
          {:ok, <<size::16>>} = :gen_tcp.recv(tcp, 2, 2000)
          size

        127 ->
          {:ok, <<size::64>>} = :gen_tcp.recv(tcp, 8, 2000)
          size

        size ->
          size
      end

    {:ok, payload} = :gen_tcp.recv(tcp, size, 2000)
    Jason.decode!(payload)
  end
end
