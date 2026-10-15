defmodule GSMLG.GaoNote.Sync do
  @moduledoc "Durable, provisioned-peer GaoNote synchronization using protocol v1."
  alias GSMLG.GaoNote.Sync.{Engine, Objects, Peers, Store}

  defdelegate register_peer(attrs), to: Peers, as: :register
  defdelegate register_ssh_peer(attrs), to: Peers, as: :register_ssh
  defdelegate authenticate_peer(fingerprint), to: Peers, as: :authenticate
  defdelegate revoke_peer(peer_id), to: Peers, as: :revoke
  defdelegate lock_objects(ids), to: Objects
  defdelegate with_object_lock(id, operation), to: Objects
  defdelegate object_referenced?(id), to: Objects, as: :referenced?

  def local_node_id, do: Store.transaction(fn -> Store.node()["node_id"] end)

  def select(peer_id, selectors) do
    with {:ok, {peer, changed}} <- Peers.select(peer_id, selectors),
         :ok <- Engine.seed(peer, changed),
         do: {:ok, peer}
  end

  def join(peer, payload) do
    with {:ok, joined} <- Peers.join(peer, payload), do: {:ok, Map.delete(joined, :changed)}
  end

  def join_ssh(payload) do
    with {:ok, joined} <- Peers.join_ssh(payload), do: {:ok, Map.delete(joined, :changed)}
  end

  def capture(note_id, opts \\ []), do: Engine.capture(note_id, opts)
  defdelegate apply(peer, event, attachment_bytes), to: Engine
  defdelegate inventory(peer), to: Engine
  defdelegate pending_ids(peer), to: Engine
  defdelegate checkout(peer, note_id), to: Engine
  defdelegate ack(peer, descriptor, lease_id), to: Engine
  defdelegate reject(peer, rejection, lease_id), to: Engine
  defdelegate retry(peer_id), to: Engine
  defdelegate release_lease(peer, lease_id), to: Engine
  defdelegate release_session(peer), to: Engine
  def pending(peer_id), do: Store.list("pending", peer_id) |> Enum.map(& &1.data["event"])
  def membership(peer_id, note_id), do: Store.get("member", note_id, peer_id)
end
