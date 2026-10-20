defmodule GSMLG.GaoNote.Workers.IndexWorker do
  @moduledoc false
  use Styx.Worker,
    queue: :gao_note_index,
    max_attempts: 10,
    unique: [period: 86_400, fields: [:worker, :args]]

  @impl Styx.Worker
  def perform(%Styx.Job{args: %{"note_id" => id}}) do
    # Read the latest saved snapshot; delayed older jobs never deliver stale content.
    case GSMLG.GaoNote.Compat.get_note(id) do
      nil -> :ok
      note -> GSMLG.GaoNote.Compat.Index.deliver(note)
    end
  end
end
