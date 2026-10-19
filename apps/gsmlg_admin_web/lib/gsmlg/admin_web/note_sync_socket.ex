defmodule GSMLG.AdminWeb.NoteSyncSocket do
  @moduledoc "Unauthenticated note synchronization on the admin endpoint."
  use Phoenix.Socket
  channel("note_sync:v1", GSMLG.AdminWeb.NoteSyncChannel)

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
