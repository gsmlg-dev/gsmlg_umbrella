defmodule GSMLG.Browser.Notifier do
  @moduledoc false

  def job_changed(job_id, reason, extra \\ %{})
      when is_binary(job_id) and is_atom(reason) and is_map(extra) do
    invalidation = Map.merge(%{job_id: job_id, reason: reason}, Map.take(extra, [:sequence]))
    message = {:browser_job_changed, invalidation}
    Phoenix.PubSub.broadcast(GSMLG.PubSub, "browser:updates", message)
    Phoenix.PubSub.broadcast(GSMLG.PubSub, "browser:job:#{job_id}", message)
  end

  def resource_changed(resource, id, reason)
      when resource in [:node, :profile, :session, :artifact] and is_binary(id) and
             is_atom(reason) do
    Phoenix.PubSub.broadcast(
      GSMLG.PubSub,
      "browser:updates",
      {:browser_changed, %{resource: resource, id: id, reason: reason}}
    )
  end
end
