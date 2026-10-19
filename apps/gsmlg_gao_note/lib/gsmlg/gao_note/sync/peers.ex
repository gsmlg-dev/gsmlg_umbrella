defmodule GSMLG.GaoNote.Sync.Peers do
  @moduledoc false
  import Ecto.Query
  alias GSMLG.GaoNote.Compat.LabelSelector
  alias GSMLG.GaoNote.Sync.{Peer, Protocol, Selectors, Store}
  alias GSMLG.Repo

  @limit 536_870_912

  def register(attrs), do: register(attrs, :mtls)

  def register_ssh(attrs) when is_map(attrs) do
    if is_nil(Map.get(attrs, :certificate_fingerprint)) and
         is_nil(Map.get(attrs, "certificate_fingerprint")),
       do: register(attrs, :ssh),
       else: {:error, :invalid_peer}
  end

  def register_ssh(_), do: {:error, :invalid_peer}

  defp register(attrs, transport) when is_map(attrs) do
    attrs =
      Map.new(~w(node_id certificate_fingerprint actor_id allowed_selectors)a, fn k ->
        {k, Map.get(attrs, k, Map.get(attrs, Atom.to_string(k)))}
      end)

    with true <- Protocol.uuid?(attrs.node_id),
         true <- transport == :ssh or Protocol.checksum?(attrs.certificate_fingerprint),
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

  defp register(_, _), do: {:error, :invalid_peer}

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

  def selected do
    Repo.all(from(p in Peer, where: p.selectors != ^[]))
    |> Enum.filter(&(selectors(&1.selectors) == :ok))
    |> Enum.map(&with_scope/1)
  end

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

  def join_ssh(%{"node_id" => node_id} = payload) do
    with true <- Protocol.uuid?(node_id),
         %Peer{certificate_fingerprint: nil} = peer <- Repo.get(Peer, node_id) do
      join(peer, payload)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def join_ssh(_), do: {:error, :unauthorized}

  def join(payload) do
    if valid_join?(payload) do
      Store.transaction(fn ->
        id = payload["node_id"]

        Repo.insert!(
          %Peer{id: id, actor_id: "note_sync:#{id}", allowed_selectors: payload["selectors"]},
          on_conflict: :nothing,
          conflict_target: [:id]
        )

        current = Repo.one!(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE"))

        join_current!(current, payload,
          certificate_fingerprint: nil,
          allowed_selectors: payload["selectors"]
        )
      end)
    else
      {:error, :invalid_join}
    end
  end

  def join(peer, payload) do
    with true <- valid_join?(payload),
         true <- payload["node_id"] == peer.id do
      Store.transaction(fn ->
        current =
          Repo.one(from(p in Peer, where: p.id == ^peer.id, lock: "FOR UPDATE")) ||
            Repo.rollback(:unauthorized)

        unless current.certificate_fingerprint == peer.certificate_fingerprint,
          do: Repo.rollback(:unauthorized)

        authorize!(current, payload["selectors"])
        join_current!(current, payload)
      end)
    else
      _ -> {:error, :unauthorized}
    end
  end

  def current!(%Peer{id: id, session_id: token, selectors: selectors} = peer)
      when is_binary(token) do
    current = Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE"))
    authorize_current!(current, peer, token, selectors)
  end

  def current!(_), do: Repo.rollback(:obsolete_session)

  def try_current!(%Peer{id: id, session_id: token, selectors: selectors} = peer)
      when is_binary(token) do
    case Repo.one(from(p in Peer, where: p.id == ^id, lock: "FOR UPDATE SKIP LOCKED")) do
      nil ->
        # A locked row is not an authentication failure. Check the committed
        # session before allowing its existing leases to be renewed without data.
        authorize_current!(Repo.get(Peer, id), peer, token, selectors)
        :busy

      current ->
        authorize_current!(current, peer, token, selectors)
    end
  end

  def try_current!(_), do: Repo.rollback(:obsolete_session)

  defp authorize_current!(%Peer{session_id: token} = current, peer, token, selectors) do
    unless current.certificate_fingerprint == peer.certificate_fingerprint,
      do: Repo.rollback(:unauthorized)

    unless current.selectors == selectors, do: Repo.rollback(:obsolete_session)
    authorize!(current, current.selectors)
    with_scope(current)
  end

  defp authorize_current!(_current, _peer, _token, _selectors),
    do: Repo.rollback(:obsolete_session)

  defp valid_join?(payload) do
    Protocol.exact_keys?(payload, ~w(protocol_version node_id selectors max_blob_bytes)) and
      payload["protocol_version"] === 1 and Protocol.uuid?(payload["node_id"]) and
      is_integer(payload["max_blob_bytes"]) and payload["max_blob_bytes"] > 0 and
      selectors(payload["selectors"]) == :ok
  end

  defp join_current!(current, payload, attrs \\ []) do
    local = Store.node()["node_id"]
    if local == current.id, do: Repo.rollback(:invalid_peer)
    changed = current.selectors != payload["selectors"]
    release_peer_leases(current.id)

    attrs =
      Keyword.merge(attrs,
        selectors: payload["selectors"],
        session_id: Ecto.UUID.generate(),
        max_blob_bytes: min(payload["max_blob_bytes"], configured_limit())
      )

    updated = Repo.update!(Ecto.Changeset.change(current, attrs)) |> establish_scope(changed)

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
  end

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
             match?({:ok, [_ | _]}, Selectors.parse(s))
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
