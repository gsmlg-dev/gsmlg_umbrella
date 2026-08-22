defmodule GSMLG.GaoNote.Audit do
  alias GSMLG.GaoNote.Log
  alias GSMLG.Repo

  def actor_id(%{id: id}) when is_binary(id), do: id
  def actor_id(%{id: id}), do: to_string(id)
  def actor_id(_actor), do: nil

  def source(actor) do
    case actor do
      %{source: source} when is_binary(source) and source != "" -> source
      %{"source" => source} when is_binary(source) and source != "" -> source
      _ -> "admin"
    end
  end

  def log(action, entity_type, entity_id, note_id, actor, details) do
    %Log{}
    |> Log.changeset(%{
      action: action,
      entity_type: entity_type,
      entity_id: entity_id,
      note_id: note_id,
      actor_id: actor_id(actor),
      source: source(actor),
      details: details || %{}
    })
    |> Repo.insert()
  end
end
