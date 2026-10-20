defmodule GSMLG.GaoNote.Sync.Record do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "gao_note_sync_records" do
    field(:kind, :string)
    field(:peer_id, Ecto.UUID)
    field(:note_id, Ecto.UUID)
    field(:data, :map)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule GSMLG.GaoNote.Sync.Peer do
  @moduledoc false
  use Ecto.Schema
  @primary_key {:id, Ecto.UUID, autogenerate: false}
  schema "gao_note_sync_peers" do
    field(:certificate_fingerprint, :string)
    field(:actor_id, :string)
    field(:allowed_selectors, {:array, :string})
    field(:selectors, {:array, :string}, default: [])
    field(:session_id, Ecto.UUID)
    field(:max_blob_bytes, :integer, default: 536_870_912)
    field(:scope_id, :string, virtual: true)
    timestamps(type: :utc_datetime_usec)
  end
end

defmodule GSMLG.GaoNote.Sync.Pin do
  @moduledoc false
  use Ecto.Schema
  @primary_key false
  schema "gao_note_sync_pins" do
    field(:owner_id, :string, primary_key: true)
    field(:storage_file_id, Ecto.UUID, primary_key: true)
  end
end

defmodule GSMLG.GaoNote.Sync.Store do
  @moduledoc false
  import Kernel, except: [node: 0]
  import Ecto.Query, except: [lock: 2]
  alias GSMLG.GaoNote.Sync.Record
  alias GSMLG.Repo

  # Session work can wait behind an apply's locks: 900 seconds plus 10 seconds
  # for ordinary work. The channel enforces each operation's shorter deadline.
  @session_transaction_timeout 910_000

  def key(kind, peer_id, identifier), do: Enum.join([kind, peer_id || "local", identifier], ":")

  def get(kind, identifier, peer_id \\ nil) do
    case Repo.get(Record, key(kind, peer_id, identifier)) do
      nil -> nil
      record -> record.data
    end
  end

  def put(kind, identifier, data, peer_id \\ nil, note_id \\ nil) do
    record = %Record{
      id: key(kind, peer_id, identifier),
      kind: kind,
      peer_id: peer_id,
      note_id: note_id,
      data: data
    }

    Repo.insert!(record, on_conflict: {:replace, [:data, :updated_at]}, conflict_target: [:id])
    record.id
  end

  def delete(kind, identifier, peer_id \\ nil) do
    Repo.delete_all(from(r in Record, where: r.id == ^key(kind, peer_id, identifier)))
    :ok
  end

  def list(kind, peer_id) do
    Repo.all(
      from(r in Record, where: r.kind == ^kind and r.peer_id == ^peer_id, order_by: r.note_id)
    )
  end

  # Only the source producer owns this read-only snapshot; it never waits on the network.
  def inventory_snapshot(peer, operation) do
    session_transaction(fn ->
      Repo.query!("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
      current = Repo.get(GSMLG.GaoNote.Sync.Peer, peer.id)

      unless current && current.session_id == peer.session_id &&
               current.selectors == peer.selectors,
             do: Repo.rollback(:obsolete_session)

      operation.()
    end)
  end

  def inventory_id_page(peer_id, cursor, limit, lane \\ :all) when limit in 1..32 do
    lane_filter =
      case lane do
        :all ->
          "TRUE"

        :pending ->
          "EXISTS (SELECT 1 FROM gao_note_sync_records p WHERE p.kind = 'pending' AND p.peer_id = $1 AND p.note_id = cohort.id)"

        :audit ->
          "NOT EXISTS (SELECT 1 FROM gao_note_sync_records p WHERE p.kind = 'pending' AND p.peer_id = $1 AND p.note_id = cohort.id)"
      end

    query = """
    SELECT id FROM (
      SELECT id FROM gao_notes
      UNION
      SELECT note_id AS id FROM gao_note_sync_records
      WHERE kind = 'member' AND peer_id = $1 AND note_id IS NOT NULL
    ) cohort
    WHERE ($2::uuid IS NULL OR id > $2) AND (#{lane_filter})
    ORDER BY id LIMIT $3
    """

    params = [Ecto.UUID.dump!(peer_id), if(cursor, do: Ecto.UUID.dump!(cursor)), limit]
    %{rows: rows} = Repo.query!(query, params)
    Enum.map(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  def list_page(kind, peer_id, cursor, limit) when limit in 1..32 do
    query =
      from(r in Record,
        where: r.kind == ^kind and r.peer_id == ^peer_id,
        order_by: r.note_id,
        limit: ^limit
      )

    query = if cursor, do: from(r in query, where: r.note_id > ^cursor), else: query
    Repo.all(query)
  end

  def lock(namespace, id) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
      "gao-note-sync:" <> namespace <> ":" <> id
    ])

    :ok
  end

  def transaction(operation, opts \\ []) do
    Repo.transaction(operation, opts)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, {:storage, error}}
  end

  def session_transaction(operation),
    do: transaction(operation, timeout: @session_transaction_timeout)

  def unwrap({:ok, result}), do: result
  def unwrap({:error, _} = error), do: error

  def node do
    lock("clock", "local")

    case get("node", "local") do
      nil ->
        node = %{"node_id" => Ecto.UUID.generate(), "millis" => 0, "counter" => 0}
        put("node", "local", node)
        node

      node ->
        node
    end
  end

  def tick(observed \\ nil) do
    node = node()
    remote_millis = if observed, do: observed["millis"], else: 0
    millis = Enum.max([System.system_time(:millisecond), node["millis"], remote_millis])

    counter =
      cond do
        millis == node["millis"] and millis == remote_millis ->
          max(node["counter"], observed["counter"]) + 1

        millis == node["millis"] ->
          node["counter"] + 1

        millis == remote_millis ->
          observed["counter"] + 1

        true ->
          0
      end

    if counter > 18_446_744_073_709_551_615 or millis > 9_223_372_036_854_775_807,
      do: Repo.rollback(:clock_overflow)

    stamp = %{"node_id" => node["node_id"], "millis" => millis, "counter" => counter}
    put("node", "local", stamp)
    stamp
  end
end
