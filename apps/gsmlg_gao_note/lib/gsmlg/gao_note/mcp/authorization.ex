defmodule GSMLG.GaoNote.MCP.Authorization do
  @moduledoc false

  @actor_keys [:actor, :current_user, "actor", "current_user"]
  @unauthorized "Admin MCP mutating tools require an actor"

  def actor(%{assigns: assigns}) when is_map(assigns) do
    Enum.find_value(@actor_keys, fn key ->
      case Map.fetch(assigns, key) do
        {:ok, actor} -> valid_actor(actor)
        :error -> nil
      end
    end) || {:error, @unauthorized}
  end

  def actor(_frame), do: {:error, @unauthorized}

  defp valid_actor(actor) when is_map(actor) do
    id = Map.get(actor, :id, Map.get(actor, "id"))

    if valid_actor_id?(id), do: {:ok, actor}
  end

  defp valid_actor(_actor), do: nil

  defp valid_actor_id?(id) when is_binary(id) do
    String.valid?(id) and String.trim(id) != "" and
      not String.contains?(id, <<0>>)
  end

  defp valid_actor_id?(_id), do: false
end
