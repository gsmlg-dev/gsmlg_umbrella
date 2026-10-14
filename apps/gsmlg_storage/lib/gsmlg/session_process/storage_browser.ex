defmodule GSMLG.SessionProcess.StorageBrowser do
  @moduledoc "Session-owned S3 snapshots shared by the session's browser tabs."

  alias GSMLG.Storage.Inventory
  alias Phoenix.SessionProcess
  alias Phoenix.SessionProcess.Action

  def refresh(session_id, inventory \\ Inventory) do
    payload = %{
      token: make_ref(),
      backend_id: inventory.current_backend_id(),
      inventory: inventory
    }

    with {:ok, _state} <- dispatch_sync(session_id, "refresh_started", payload) do
      SessionProcess.dispatch_async(session_id, "load", payload,
        reducers: [:storage],
        cancel_ref: {:storage, payload.token}
      )
    end
  end

  def snapshot(session_id, inventory \\ Inventory) do
    current_id = inventory.current_backend_id()

    case SessionProcess.select_state(session_id, & &1.storage) do
      %{backend_id: ^current_id} = snapshot ->
        snapshot

      %{} ->
        with :ok <- invalidate(session_id, inventory) do
          SessionProcess.select_state(session_id, & &1.storage)
        end

      {:error, _reason} = error ->
        error
    end
  end

  def subscribe(session_id, inventory \\ Inventory) do
    with %{} <- snapshot(session_id, inventory) do
      SessionProcess.subscribe(session_id, & &1.storage, :storage_snapshot)
    end
  end

  def invalidate(session_id, inventory \\ Inventory) do
    case dispatch_sync(session_id, "invalidate", %{backend_id: inventory.current_backend_id()}) do
      {:ok, _state} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_sync(session_id, type, payload) do
    action = Action.new(type, payload, %{reducers: [:storage]})
    SessionProcess.call(session_id, {:dispatch_action, action})
  end
end
