defmodule GSMLG.AdminWeb.NoteSyncSocketTest do
  use ExUnit.Case, async: false
  alias GSMLG.AdminWeb.{NoteSyncSocket, NoteSyncSerializer}

  test "connects without credentials or sync configuration" do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)
    Application.delete_env(:gsmlg_gao_note, :note_sync)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    assert {:ok, socket} = NoteSyncSocket.connect(%{}, %Phoenix.Socket{}, %{})
    assert NoteSyncSocket.id(socket) == nil
    refute Map.has_key?(socket.assigns, :sync_peer)
  end

  test "accepts direct remote connections without a proxy or certificate" do
    assert {:ok, _} =
             NoteSyncSocket.connect(%{}, %Phoenix.Socket{}, %{
               peer_data: %{address: {10, 100, 10, 20}},
               x_headers: []
             })
  end

  test "headers and query parameters do not bind a peer identity" do
    assert {:ok, socket} =
             NoteSyncSocket.connect(
               %{"actor_id" => "spoof", "node_id" => "spoof"},
               %Phoenix.Socket{},
               %{
                 x_headers: [{"x-note-sync-client-fingerprint", "ignored"}]
               }
             )

    refute Map.has_key?(socket.assigns, :sync_peer)
  end

  test "V2 serializer preserves ref and join identity" do
    frame = ~s(["join","request","note_sync:v1","phx_reply",{"status":"ok","response":{}}])

    assert %Phoenix.Socket.Message{join_ref: "join", ref: "request"} =
             NoteSyncSerializer.decode!(frame, opcode: :text)
  end

  test "complete message cap covers fragmented oversized messages and rejects invalid frame types" do
    for frame <- [
          ~s([null,"1","note_sync:v1","ack",{}]),
          ~s(["1",2,"note_sync:v1","ack",{}]),
          ~s(["1",null,"note_sync:v1","ack",[]]),
          Jason.encode!([
            "1",
            nil,
            "note_sync:v1",
            "blob_chunk",
            %{"data" => String.duplicate("a", 131_072)}
          ])
        ] do
      assert_raise ArgumentError, fn -> NoteSyncSerializer.decode!(frame, opcode: :text) end
    end

    assert_raise ArgumentError, fn -> NoteSyncSerializer.decode!("binary", opcode: :binary) end
  end
end
