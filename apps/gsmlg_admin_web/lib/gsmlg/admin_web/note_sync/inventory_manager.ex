defmodule GSMLG.AdminWeb.NoteSync.InventoryManager do
  @moduledoc "Session-owned, disk-spooled exact cohort with one page resident."
  alias GSMLG.GaoNote.Sync.{Engine, Store}
  @page_size 32

  def new(root, round_id) do
    %{
      directory: Path.join(root, "inventory-" <> round_id),
      round_id: round_id,
      next_page: 1,
      page_notes: 0,
      eligible_notes: 0,
      page_active: false,
      checked_notes: 0,
      equal_notes: 0,
      planned_notes: 0,
      superseded_notes: 0,
      blocked_notes: 0,
      pages_checked: 0,
      mode: "initial_scan",
      state: "running",
      error: nil,
      last_progress_at: System.system_time(:millisecond),
      source: source_progress(nil, 0, 0, false)
    }
  end

  def scan(peer, manager, notify) do
    with :ok <- File.mkdir_p(manager.directory) do
      lanes = %{
        pending: %{cursor: nil, ids: [], done: false},
        audit: %{cursor: nil, ids: [], done: false},
        streak: 0
      }

      Store.inventory_snapshot(peer, fn -> produce(peer, manager, lanes, 0, 0, nil, notify) end)
    end
  end

  defp produce(peer, manager, lanes, pages, notes, cursor, notify) do
    {ids, lanes} = next_page(peer, lanes, [], @page_size)

    if ids == [] do
      progress = source_progress(cursor, pages, notes, true)
      write_progress!(manager, progress)
      notify.(progress)
      progress
    else
      page = pages + 1
      path = page_path(manager, page)
      File.write!(path <> ".tmp", Enum.join(ids, "\n") <> "\n")
      File.rename!(path <> ".tmp", path)
      progress = source_progress(List.last(ids), page, notes + length(ids), false)
      write_progress!(manager, progress)
      notify.(progress)
      produce(peer, manager, lanes, page, notes + length(ids), List.last(ids), notify)
    end
  end

  defp next_page(_peer, lanes, ids, 0), do: {Enum.reverse(ids), lanes}

  defp next_page(peer, lanes, ids, remaining) do
    lanes = lanes |> fill_lane(peer, :pending) |> fill_lane(peer, :audit)

    lane =
      cond do
        lanes.audit.ids != [] and lanes.streak >= 8 -> :audit
        lanes.pending.ids != [] -> :pending
        lanes.audit.ids != [] -> :audit
        true -> nil
      end

    if lane do
      [id | rest] = lanes[lane].ids
      lanes = Map.put(lanes, lane, %{lanes[lane] | ids: rest})
      lanes = %{lanes | streak: if(lane == :pending, do: lanes.streak + 1, else: 0)}
      next_page(peer, lanes, [id | ids], remaining - 1)
    else
      {Enum.reverse(ids), lanes}
    end
  end

  defp fill_lane(lanes, peer, lane) do
    case lanes[lane] do
      %{ids: [], done: false} = state ->
        ids = Store.inventory_id_page(peer.id, state.cursor, @page_size, lane)
        authorized = Enum.filter(ids, &Engine.inventory_authorized?(peer, &1))
        next = %{state | ids: authorized, cursor: List.last(ids) || state.cursor, done: ids == []}
        lanes = Map.put(lanes, lane, next)
        if authorized == [] and ids != [], do: fill_lane(lanes, peer, lane), else: lanes

      _ ->
        lanes
    end
  end

  def read_page(peer, manager) do
    case File.read(page_path(manager, manager.next_page)) do
      {:ok, bytes} ->
        ids = String.split(bytes, "\n", trim: true)

        with true <- length(ids) <= @page_size,
             {:ok, slots} <- classify(peer, ids),
             %{} = source <- source(manager) do
          # The atomic page is proof of enumeration even when the producer's
          # coalesced notification or source.json rename has not arrived yet.
          observed =
            Map.merge(source, %{
              "pages_scanned" => max(source["pages_scanned"], manager.next_page),
              "notes_scanned" =>
                max(source["notes_scanned"], (manager.next_page - 1) * @page_size + length(ids)),
              "source_cursor" =>
                if(source["pages_scanned"] >= manager.next_page,
                  do: source["source_cursor"],
                  else: List.last(ids)
                )
            })

          File.rm(page_path(manager, manager.next_page))
          {:ok, %{ids: ids, slots: slots, source: observed}}
        else
          false -> {:error, :invalid_inventory_page}
          error -> error
        end

      {:error, :enoent} ->
        case source(manager) do
          %{"scan_complete" => true} = source ->
            if source["pages_scanned"] < manager.next_page,
              do: {:ok, {:done, source}},
              else: {:error, :missing_inventory_page}

          %{} ->
            {:ok, :waiting}

          {:error, reason} ->
            {:error, {:storage, reason}}
        end

      {:error, reason} ->
        {:error, {:storage, reason}}
    end
  end

  def source(manager) do
    with {:ok, bytes} <- File.read(Path.join(manager.directory, "source.json")),
         {:ok, progress} <- Jason.decode(bytes),
         do: progress
  end

  def progress(manager) do
    source = manager.source
    classified = manager.equal_notes + manager.planned_notes + manager.superseded_notes

    Map.merge(source, %{
      "mode" => manager.mode,
      "state" => manager.state,
      "error" => manager.error,
      "last_progress_at" => max(source["last_progress_at"], manager.last_progress_at),
      "page_size" => @page_size,
      "pages_checked" => manager.pages_checked,
      "checked_notes" => max(manager.checked_notes, classified),
      "equal_notes" => manager.equal_notes,
      "planned_notes" => manager.planned_notes,
      "superseded_notes" => manager.superseded_notes,
      "blocked_notes" => manager.blocked_notes,
      # Changes after the frozen scan still belong to this session's round.
      "total_notes" =>
        if(source["scan_complete"], do: max(source["notes_scanned"], classified), else: nil)
    })
  end

  def observe_source(manager, source) do
    old = manager.source

    latest =
      if {source["pages_scanned"], source["notes_scanned"]} >=
           {old["pages_scanned"], old["notes_scanned"]},
         do: source,
         else: old

    merged =
      Map.merge(latest, %{
        "pages_scanned" => max(old["pages_scanned"], source["pages_scanned"]),
        "notes_scanned" => max(old["notes_scanned"], source["notes_scanned"]),
        "scan_complete" => old["scan_complete"] or source["scan_complete"],
        "last_progress_at" => max(old["last_progress_at"], source["last_progress_at"])
      })

    %{manager | source: merged}
  end

  def page_loaded(manager, count, eligible),
    do: %{
      manager
      | page_active: true,
        page_notes: count,
        eligible_notes: manager.eligible_notes + eligible
    }

  # The session owns these small disk markers, so retries across page boundaries
  # never require retaining the whole cohort in the channel process.
  def classify(manager, note_id, outcome)
      when outcome in [:equal, :planned, :superseded, :blocked, :delivered] do
    directory = Path.join(manager.directory, "classifications")
    path = Path.join(directory, note_id)

    previous =
      case File.read(path) do
        {:ok, value} -> value
        {:error, :enoent} -> nil
      end

    current = next_classification(previous, outcome)

    if previous == current do
      manager
    else
      File.mkdir_p!(directory)
      File.write!(path, current)

      manager
      |> adjust_classification(previous, -1)
      |> adjust_classification(current, 1)
      |> Map.put(:last_progress_at, System.system_time(:millisecond))
    end
  end

  # A confirmed note must not be counted again as equal/superseded during an
  # overlapping audit. Later failures remain visible until its next retry.
  defp next_classification(previous, outcome)
       when previous in ["delivered", "delivered_blocked"] do
    case outcome do
      :blocked -> "delivered_blocked"
      kind when kind in [:equal, :superseded] -> previous
      _ -> "delivered"
    end
  end

  defp next_classification(_previous, outcome), do: Atom.to_string(outcome)

  defp adjust_classification(manager, nil, _delta), do: manager

  defp adjust_classification(manager, kind, delta) when kind in ["blocked", "delivered_blocked"],
    do: %{
      manager
      | planned_notes: manager.planned_notes + delta,
        blocked_notes: manager.blocked_notes + delta
    }

  defp adjust_classification(manager, "equal", delta),
    do: %{manager | equal_notes: manager.equal_notes + delta}

  defp adjust_classification(manager, kind, delta) when kind in ["planned", "delivered"],
    do: %{manager | planned_notes: manager.planned_notes + delta}

  defp adjust_classification(manager, "superseded", delta),
    do: %{manager | superseded_notes: manager.superseded_notes + delta}

  def page_done(%{page_active: false} = manager), do: manager

  def page_done(manager) do
    %{
      manager
      | page_active: false,
        page_notes: 0,
        next_page: manager.next_page + 1,
        checked_notes: manager.checked_notes + manager.page_notes,
        pages_checked: manager.pages_checked + 1,
        last_progress_at: System.system_time(:millisecond)
    }
  end

  def valid_progress?(progress) when is_map(progress) do
    required =
      ~w(mode page_size pages_scanned pages_checked notes_scanned scan_complete source_cursor last_progress_at checked_notes total_notes)

    optional = ~w(planned_notes equal_notes superseded_notes blocked_notes)

    Enum.all?(required, &Map.has_key?(progress, &1)) and
      Enum.all?(Map.keys(progress), &(&1 in (required ++ optional ++ ~w(state error)))) and
      (is_nil(progress["state"]) or progress["state"] in ~w(running idle failed)) and
      (is_nil(progress["error"]) or valid_error?(progress["error"])) and
      Enum.all?(optional, fn field ->
        not Map.has_key?(progress, field) or
          (is_integer(progress[field]) and progress[field] in 0..18_446_744_073_709_551_615)
      end) and
      progress["mode"] in ~w(initial_scan changes) and progress["page_size"] == @page_size and
      Enum.all?(~w(pages_scanned pages_checked notes_scanned checked_notes), fn field ->
        is_integer(progress[field]) and progress[field] in 0..18_446_744_073_709_551_615
      end) and is_boolean(progress["scan_complete"]) and
      (is_nil(progress["source_cursor"]) or
         GSMLG.GaoNote.Sync.Protocol.uuid?(progress["source_cursor"])) and
      is_integer(progress["last_progress_at"]) and
      progress["last_progress_at"] in 0..9_223_372_036_854_775_807 and
      (is_nil(progress["total_notes"]) or
         (is_integer(progress["total_notes"]) and
            progress["total_notes"] in 0..18_446_744_073_709_551_615))
  end

  def valid_progress?(_), do: false

  def accept_status(previous, payload) do
    valid =
      GSMLG.GaoNote.Sync.Protocol.exact_keys?(payload, ~w(round_id status_seq progress)) and
        GSMLG.GaoNote.Sync.Protocol.uuid?(payload["round_id"]) and
        is_integer(payload["status_seq"]) and
        payload["status_seq"] in 1..18_446_744_073_709_551_615 and
        valid_progress?(payload["progress"])

    cond do
      not valid ->
        {:error, "invalid_manager_status"}

      previous && payload["status_seq"] < previous["status_seq"] ->
        {:ok, previous}

      previous && payload["status_seq"] == previous["status_seq"] && payload != previous ->
        {:error, "status_conflict"}

      true ->
        {:ok, payload}
    end
  end

  defp valid_error?(error) do
    GSMLG.GaoNote.Sync.Protocol.exact_keys?(error, ~w(code retryable)) and
      is_binary(error["code"]) and byte_size(error["code"]) in 1..64 and
      is_boolean(error["retryable"])
  end

  defp classify(peer, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, slots} ->
      case Engine.classify_inventory_note(peer, id, false) do
        {:ok, nil} -> {:cont, {:ok, slots}}
        {:ok, slot} -> {:cont, {:ok, [slot | slots]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, slots} -> {:ok, Enum.reverse(slots)}
      error -> error
    end
  end

  defp page_path(manager, page), do: Path.join(manager.directory, "page-#{page}.ids")

  defp source_progress(cursor, pages, notes, complete),
    do: %{
      "pages_scanned" => pages,
      "notes_scanned" => notes,
      "scan_complete" => complete,
      "source_cursor" => cursor,
      "last_progress_at" => System.system_time(:millisecond)
    }

  defp write_progress!(manager, progress) do
    path = Path.join(manager.directory, "source.json")
    File.write!(path <> ".tmp", Jason.encode!(progress))
    File.rename!(path <> ".tmp", path)
  end
end
