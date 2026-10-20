defmodule GSMLG.AdminWeb.NoteSync.TaskSync do
  @moduledoc false
  alias GSMLG.GaoNote.Sync.Protocol

  @operations ~w(inventory_start state_query transfer_begin attachment_begin blob_chunk blob_end transfer_commit inventory_complete transfer_abort)
  @terminal ~w(succeeded failed cancelled)
  @u64 18_446_744_073_709_551_615

  def new(origin), do: %{origin: origin, high_water: 0, entries: %{}, terminal: []}
  def terminal?(state), do: state in @terminal
  def category("inventory_start"), do: :inventory
  def category("state_query"), do: :query

  def category(operation) when operation in ~w(inventory_complete transfer_abort),
    do: :housekeeping

  def category(_), do: :transfer

  def id_sequence(id, origin) when is_binary(id) and byte_size(id) <= 57 do
    case String.split(id, ":") do
      [^origin, sequence] ->
        case Integer.parse(sequence) do
          {number, ""} when number > 0 and number <= @u64 ->
            if Integer.to_string(number) == sequence, do: {:ok, number}, else: :error

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  def id_sequence(_, _), do: :error

  def admit(ledger, command) do
    with true <- Protocol.exact_keys?(command, ~w(task_id operation payload)),
         true <- command["operation"] in @operations and is_map(command["payload"]),
         {:ok, sequence} <- id_sequence(command["task_id"], ledger.origin) do
      digest =
        Protocol.sha256(:erlang.term_to_binary(Map.drop(command, ["task_id"]), [:deterministic]))

      id = command["task_id"]

      case ledger.entries[id] do
        %{digest: ^digest, status: status} ->
          {:replay, ledger, status}

        entry when not is_nil(entry) ->
          {:error, "task_id_conflict"}

        nil when sequence <= ledger.high_water ->
          {:error, "retired"}

        nil when sequence != ledger.high_water + 1 ->
          {:error, "invalid_task_id"}

        nil ->
          category = category(command["operation"])

          busy =
            Enum.any?(ledger.entries, fn {_, entry} ->
              not terminal?(entry.status["state"]) and entry.category == category
            end)

          status = snapshot(id, 1, "queued", phase(command["operation"]), %{}, nil, nil)

          entry = %{
            digest: digest,
            operation: command["operation"],
            category: category,
            context: Map.take(command["payload"], ~w(transfer_id blob_id offset)),
            status: status
          }

          ledger = %{ledger | high_water: sequence, entries: Map.put(ledger.entries, id, entry)}

          if busy do
            {ledger, failed} =
              update(ledger, id, "failed", "waiting", %{}, nil, %{
                "code" => "busy",
                "retryable" => true
              })

            {:busy, ledger, failed}
          else
            {:new, ledger, status}
          end
      end
    else
      _ -> {:error, "invalid_task_id"}
    end
  end

  def get(ledger, id) do
    case ledger.entries[id] do
      %{status: status} ->
        {:ok, status}

      nil ->
        case id_sequence(id, ledger.origin) do
          {:ok, n} when n <= ledger.high_water -> {:error, "retired"}
          _ -> {:error, "unknown_task"}
        end
    end
  end

  def update(ledger, id, state, phase, progress, result, error) do
    entry = Map.fetch!(ledger.entries, id)
    previous = entry.status
    proposed = snapshot(id, previous["status_seq"], state, phase, progress, result, error)

    if terminal?(previous["state"]) or previous == proposed do
      {ledger, previous}
    else
      status = %{proposed | "status_seq" => previous["status_seq"] + 1}
      ledger = %{ledger | entries: Map.put(ledger.entries, id, %{entry | status: status})}
      ledger = if terminal?(state), do: retain_terminal(ledger, id), else: ledger
      {ledger, status}
    end
  end

  def phase("inventory_start"), do: "checking"
  def phase("state_query"), do: "checking"
  def phase("transfer_commit"), do: "applying"
  def phase("transfer_abort"), do: "cancelling"
  def phase(_), do: "transferring"

  def valid_status?(status) do
    Protocol.exact_keys?(status, ~w(task_id status_seq state phase progress result error)) and
      is_binary(status["task_id"]) and byte_size(status["task_id"]) <= 57 and
      is_integer(status["status_seq"]) and status["status_seq"] in 1..@u64 and
      status["state"] in ["queued", "running" | @terminal] and
      is_binary(status["phase"]) and byte_size(status["phase"]) in 1..64 and
      is_map(status["progress"]) and byte_size(Jason.encode!(status["progress"])) <= 1024 and
      valid_outcome?(status)
  end

  def accept_status(previous, status) do
    cond do
      not valid_status?(status) ->
        {:error, :invalid_status}

      is_nil(previous) ->
        {:ok, status}

      previous == status ->
        {:ok, previous}

      status["status_seq"] == previous["status_seq"] ->
        {:error, :status_conflict}

      terminal?(previous["state"]) ->
        {:error, :terminal_conflict}

      status["status_seq"] < previous["status_seq"] ->
        {:ok, previous}

      previous["state"] == "running" and status["state"] == "queued" ->
        {:error, :state_regression}

      true ->
        {:ok, status}
    end
  end

  defp valid_outcome?(%{"state" => "succeeded", "result" => result, "error" => nil}),
    do: is_map(result)

  defp valid_outcome?(%{"state" => "failed", "result" => nil, "error" => error}),
    do: valid_error?(error)

  defp valid_outcome?(%{"state" => "cancelled", "result" => nil, "error" => nil}), do: true

  defp valid_outcome?(%{"state" => state, "result" => nil, "error" => error})
       when state in ~w(queued running),
       do: is_nil(error) or valid_error?(error)

  defp valid_outcome?(_), do: false

  defp valid_error?(error),
    do:
      Protocol.exact_keys?(error, ~w(code retryable)) and
        is_binary(error["code"]) and byte_size(error["code"]) in 1..64 and
        is_boolean(error["retryable"])

  defp snapshot(id, sequence, state, phase, progress, result, error),
    do: %{
      "task_id" => id,
      "status_seq" => sequence,
      "state" => state,
      "phase" => phase,
      "progress" => progress,
      "result" => result,
      "error" => error
    }

  defp retain_terminal(ledger, id) do
    ids = ledger.terminal ++ [id]

    case length(ids) do
      n when n <= 64 ->
        %{ledger | terminal: ids}

      _ ->
        [old | rest] = ids
        %{ledger | terminal: rest, entries: Map.delete(ledger.entries, old)}
    end
  end
end
