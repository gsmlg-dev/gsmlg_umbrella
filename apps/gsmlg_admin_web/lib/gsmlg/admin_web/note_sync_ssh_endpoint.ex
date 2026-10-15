defmodule GSMLG.AdminWeb.NoteSyncSSHEndpoint do
  @moduledoc "Dedicated loopback endpoint exposing only the SSH note-sync socket."
  use Phoenix.Endpoint, otp_app: :gsmlg_admin_web

  socket("/note-sync", GSMLG.AdminWeb.NoteSyncSSHSocket,
    websocket: [
      log: false,
      timeout: 60_000,
      max_frame_size: 131_072,
      connect_info: [:peer_data]
    ],
    longpoll: false,
    serializer: [{GSMLG.AdminWeb.NoteSyncSerializer, "~> 2.0.0"}]
  )

  plug :not_found

  defp not_found(conn, _opts), do: Plug.Conn.send_resp(conn, 404, "Not Found")
end
