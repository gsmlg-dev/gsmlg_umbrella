defmodule GSMLG.AdminWeb.NoteSyncSSHSocket do
  @moduledoc "Private loopback transport for host-managed SSH tunnels."
  use Phoenix.Socket
  channel("note_sync:v1", GSMLG.AdminWeb.NoteSyncChannel)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: {127, 0, 0, 1}}}) do
    config = Application.get_env(:gsmlg_gao_note, :note_sync, %{})

    if config[:ssh_enabled] == true,
      do: {:ok, assign(socket, :sync_transport, :ssh_tunnel)},
      else: :error
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(_socket), do: nil
end
