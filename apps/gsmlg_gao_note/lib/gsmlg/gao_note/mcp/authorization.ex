defmodule GSMLG.GaoNote.MCP.Authorization do
  @moduledoc false

  def actor(%{assigns: %{actor: %{id: _id} = actor}}), do: {:ok, actor}
  def actor(%{assigns: %{current_user: %{id: _id} = actor}}), do: {:ok, actor}
  def actor(%{assigns: %{"actor" => %{id: _id} = actor}}), do: {:ok, actor}
  def actor(%{assigns: %{"current_user" => %{id: _id} = actor}}), do: {:ok, actor}
  def actor(_frame), do: {:error, "Admin MCP mutating tools require an actor"}
end
