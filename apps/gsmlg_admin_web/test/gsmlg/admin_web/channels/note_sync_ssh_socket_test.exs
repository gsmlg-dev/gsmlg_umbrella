defmodule GSMLG.AdminWeb.NoteSyncSSHSocketTest do
  use ExUnit.Case, async: false
  alias GSMLG.AdminWeb.NoteSyncSSHSocket

  setup do
    previous = Application.get_env(:gsmlg_gao_note, :note_sync)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:gsmlg_gao_note, :note_sync),
        else: Application.put_env(:gsmlg_gao_note, :note_sync, previous)
    end)
  end

  test "SSH transport is disabled independently of the mTLS ingress" do
    for config <- [%{}, %{enabled: true}, %{ssh_enabled: false}] do
      Application.put_env(:gsmlg_gao_note, :note_sync, config)

      assert :error =
               NoteSyncSSHSocket.connect(%{}, %Phoenix.Socket{}, %{
                 peer_data: %{address: {127, 0, 0, 1}}
               })
    end
  end

  test "only actual loopback peers connect without certificate or query identity" do
    Application.put_env(:gsmlg_gao_note, :note_sync, %{enabled: false, ssh_enabled: true})

    assert {:ok, socket} =
             NoteSyncSSHSocket.connect(%{}, %Phoenix.Socket{}, %{
               peer_data: %{address: {127, 0, 0, 1}}
             })

    assert socket.assigns.sync_transport == :ssh_tunnel
    refute Map.has_key?(socket.assigns, :sync_peer)
    assert NoteSyncSSHSocket.id(socket) == nil

    assert {:ok, spoofed} =
             NoteSyncSSHSocket.connect(
               %{"node_id" => "spoof", "actor_id" => "spoof"},
               %Phoenix.Socket{},
               %{
                 peer_data: %{address: {127, 0, 0, 1}},
                 x_headers: [{"x-note-sync-client-fingerprint", String.duplicate("a", 64)}]
               }
             )

    assert spoofed.assigns == socket.assigns

    for address <- [{203, 0, 113, 4}, {0, 0, 0, 0}] do
      assert :error =
               NoteSyncSSHSocket.connect(%{}, %Phoenix.Socket{}, %{
                 peer_data: %{address: address},
                 x_headers: [{"x-forwarded-for", "127.0.0.1"}]
               })
    end

    assert :error = NoteSyncSSHSocket.connect(%{}, %Phoenix.Socket{}, %{})
  end
end
