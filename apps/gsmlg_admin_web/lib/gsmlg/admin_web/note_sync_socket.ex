defmodule GSMLG.AdminWeb.NoteSyncSocket do
  @moduledoc "Certificate identity from an explicitly trusted, verified mTLS ingress."
  use Phoenix.Socket
  alias GSMLG.GaoNote.Sync
  channel("note_sync:v1", GSMLG.AdminWeb.NoteSyncChannel)

  @impl true
  def connect(_params, socket, %{peer_data: %{address: address}, x_headers: headers}) do
    config = Application.get_env(:gsmlg_gao_note, :note_sync, %{})
    fingerprints = for {"x-note-sync-client-fingerprint", value} <- headers, do: value

    with true <- config[:enabled] == true,
         true <- trusted?(address, config[:trusted_proxy_ips] || []),
         [fingerprint] <- fingerprints,
         true <- is_binary(fingerprint) and Regex.match?(~r/\A[0-9a-f]{64}\z/, fingerprint),
         {:ok, peer} <- Sync.authenticate_peer(fingerprint) do
      {:ok, assign(socket, :sync_peer, peer)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "note_sync:#{socket.assigns.sync_peer.id}"

  defp trusted?(address, ips) do
    Enum.any?(ips, fn ip ->
      :inet.parse_strict_address(String.to_charlist(ip)) == {:ok, address}
    end)
  end
end
