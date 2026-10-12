defmodule GSMLG.AdminWeb.NoteSyncSocketTest do
  use ExUnit.Case, async: false
  alias GSMLG.AdminWeb.{NoteSyncSocket, NoteSyncSerializer}

  setup do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)

    Application.put_env(:gsmlg_gao_note, :note_sync, %{
      enabled: true,
      trusted_proxy_ips: ["127.0.0.1"]
    })

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)

    :ok
  end

  test "ingress is disabled by default and missing connection identity fails closed" do
    Application.delete_env(:gsmlg_gao_note, :note_sync)

    assert :error =
             NoteSyncSocket.connect(%{}, %Phoenix.Socket{}, %{
               peer_data: %{address: {127, 0, 0, 1}},
               x_headers: [{"x-note-sync-client-fingerprint", String.duplicate("a", 64)}]
             })

    assert :error = NoteSyncSocket.connect(%{"actor_id" => "spoof"}, %Phoenix.Socket{}, %{})
  end

  test "actual untrusted peer cannot spoof trusted address with forwarded header" do
    info = %{
      peer_data: %{address: {203, 0, 113, 4}},
      x_headers: [
        {"x-forwarded-for", "127.0.0.1"},
        {"x-note-sync-client-fingerprint", String.duplicate("a", 64)}
      ]
    }

    assert :error = NoteSyncSocket.connect(%{}, %Phoenix.Socket{}, info)
  end

  test "missing duplicate uppercase and malformed fingerprint headers fail closed" do
    for headers <- [
          [],
          [{"x-note-sync-client-fingerprint", "a"}],
          [{"x-note-sync-client-fingerprint", String.duplicate("A", 64)}],
          [
            {"x-note-sync-client-fingerprint", String.duplicate("a", 64)},
            {"x-note-sync-client-fingerprint", String.duplicate("a", 64)}
          ]
        ] do
      assert :error =
               NoteSyncSocket.connect(%{}, %Phoenix.Socket{}, %{
                 peer_data: %{address: {127, 0, 0, 1}},
                 x_headers: headers
               })
    end
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
