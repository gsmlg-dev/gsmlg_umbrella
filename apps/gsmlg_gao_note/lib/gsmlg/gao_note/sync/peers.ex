defmodule GSMLG.GaoNote.Sync.Peers do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote.Compat.LabelSelector
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Store}
  alias GSMLG.Repo

  @limit 536_870_912

  def register(attrs) when is_map(attrs) do
    attrs =
      Map.new(~w(node_id certificate_fingerprint actor_id allowed_selectors)a, fn k ->
        {k, Map.get(attrs, k, Map.get(attrs, Atom.to_string(k)))}
      end)

    with true <- Protocol.uuid?(attrs.node_id),
         true <- Protocol.checksum?(attrs.certificate_fingerprint),
         true <- is_binary(attrs.actor_id) and String.trim(attrs.actor_id) != "",
         :ok <- selectors(attrs.allowed_selectors) do
      %Peer{id: attrs.node_id}
      |> Ecto.Changeset.change(Map.drop(attrs, [:node_id]))
      |> Ecto.Changeset.unique_constraint(:id, name: :gao_note_sync_peers_pkey)
      |> Ecto.Changeset.unique_constraint(:certificate_fingerprint)
      |> Repo.insert()
    else
      _ -> {:error, :invalid_peer}
    end
  end

  def register(_), do: {:error, :invalid_peer}

  def authenticate(fingerprint) do
    if Protocol.checksum?(fingerprint) do
      case Repo.get_by(Peer, certificate_fingerprint: fingerprint) do
        nil -> {:error, :unauthorized}
        %Peer{allowed_selectors: []} -> {:error, :unauthorized}
        peer -> {:ok, peer}
      end
    else
      {:error, :unauthorized}
    end
  end

  def selected,
    do: Repo.all(from(p in Peer, where: p.selectors != ^[])) |> Enum.map(&with_scope/1)

  def select(id, requested) do
    Store.transaction(fn ->
      peer =
        Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:unauthorized)

      authorize!(peer, requested)
      changed = peer.selectors != requested
      if changed, do: release_peer_leases(id)

      attrs =
        if changed, do: [selectors: requested, session_id: nil], else: [selectors: requested]

      updated = Repo.update!(Ecto.Changeset.change(peer, attrs)) |> establish_scope(changed)
      {updated, changed}
    end)
    |> case do
      {:ok, {peer, true}} = result ->
        disconnect(peer.id)
        result

      result ->
        result
    end
  end

  def revoke(id) do
    Store.transaction(fn ->
      peer =
        Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE")) ||
          Repo.rollback(:unauthorized)

      Repo.update!(
        Ecto.Changeset.change(peer, allowed_selectors: [], selectors: [], session_id: nil)
      )

      release_peer_leases(id)
      :ok
    end)
    |> case do
      {:ok, :ok} -> disconnect(id)
      {:error, _} = error -> error
    end
  end

  def join(peer, payload) do
    with true <-
           Protocol.exact_keys?(payload, ~w(protocol_version node_id selectors max_blob_bytes)),
         1 <- payload["protocol_version"],
         true <- payload["node_id"] == peer.id,
         limit when is_integer(limit) and limit > 0 <- payload["max_blob_bytes"],
         :ok <- selectors(payload["selectors"]) do
      Store.transaction(fn ->
        current =
          Repo.one(from(p in Peer, where: p.id == ^peer.id, lock: "FOR UPDATE")) ||
            Repo.rollback(:unauthorized)

        unless current.certificate_fingerprint == peer.certificate_fingerprint,
          do: Repo.rollback(:unauthorized)

        authorize!(current, payload["selectors"])
        local = Store.node()["node_id"]
        if local == peer.id, do: Repo.rollback(:invalid_peer)
        changed = current.selectors != payload["selectors"]
        release_peer_leases(current.id)

        updated =
          Repo.update!(
            Ecto.Changeset.change(current,
              selectors: payload["selectors"],
              session_id: Ecto.UUID.generate(),
              max_blob_bytes: min(limit, configured_limit())
            )
          )
          |> establish_scope(changed)

        %{
          peer: updated,
          response: %{
            "protocol_version" => 1,
            "node_id" => local,
            "selectors" => updated.selectors,
            "max_blob_bytes" => configured_limit()
          },
          changed: changed
        }
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def current!(%Peer{id: id, session_id: token, selectors: selectors} = peer)
      when is_binary(token) do
    case Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE")) do
      %Peer{session_id: ^token} = current ->
        unless current.certificate_fingerprint == peer.certificate_fingerprint,
          do: Repo.rollback(:unauthorized)

        unless current.selectors == selectors, do: Repo.rollback(:obsolete_session)
        authorize!(current, current.selectors)
        with_scope(current)

      _ ->
        Repo.rollback(:obsolete_session)
    end
  end

  def current!(_), do: Repo.rollback(:obsolete_session)

  defp establish_scope(peer, changed) do
    if changed or is_nil(Store.get("scope", "current", peer.id)) do
      Store.put("scope", "current", %{"scope_id" => Ecto.UUID.generate()}, peer.id)
    end

    with_scope(peer)
  end

  defp with_scope(peer) do
    scope = Store.get("scope", "current", peer.id)
    %{peer | scope_id: if(scope, do: scope["scope_id"])}
  end

  defp disconnect(id) do
    topic = "note_sync:#{id}"

    Phoenix.PubSub.broadcast(GSMLG.PubSub, topic, %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "disconnect",
      payload: %{}
    })
  end

  def release_peer_leases(id) do
    Store.list("lease", id) |> Enum.each(fn r -> Repo.delete!(r) end)
    :ok
  end

  def matches?(snapshot, requested) when is_map(snapshot) do
    labels =
      Enum.map(snapshot["labels"], fn l ->
        %{key: l["key"], value: l["value"], value_type: l["value_type"]}
      end)

    Enum.any?(requested, fn selector ->
      {:ok, conditions} = LabelSelector.parse(selector)
      LabelSelector.matches_all?(labels, conditions)
    end)
  end

  def matches?(_, _), do: false

  defp authorize!(peer, requested) do
    unless selectors(requested) == :ok and Enum.all?(requested, &(&1 in peer.allowed_selectors)),
      do: Repo.rollback(:unauthorized)
  end

  defp selectors(values) when is_list(values) and values != [] do
    if values == Enum.sort(Enum.uniq(values)) and
         Enum.all?(values, fn s ->
           is_binary(s) and byte_size(s) in 1..4096 and
             match?({:ok, [_ | _]}, LabelSelector.parse(s))
         end),
       do: :ok,
       else: {:error, :invalid_selectors}
  end

  defp selectors(_), do: {:error, :invalid_selectors}

  defp configured_limit do
    config = Application.get_env(:gsmlg_gao_note, :note_sync, [])
    min(config[:max_blob_bytes] || @limit, @limit)
  end
end
