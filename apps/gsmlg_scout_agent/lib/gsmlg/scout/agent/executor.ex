defmodule GSMLG.Scout.Agent.Executor do
  @moduledoc """
  Executes a single fetch job through Lightpanda.
  """

  alias GSMLG.Scout.Agent.LightpandaPool
  alias GSMLG.Scout.Fetch.{Job, Result}
  alias GSMLG.Scout.Markdown
  alias GSMLG.Scout.Settings

  def fetch(%Job{} = job) do
    started_at = System.monotonic_time(:millisecond)
    settings = Settings.get()
    agent = settings["agent"]

    opts =
      job.browser
      |> Map.put("timeout_ms", job.timeout_ms)
      |> Map.put("lightpanda_path", agent["lightpanda_path"])

    case LightpandaPool.fetch(job.url, opts) do
      {:ok, payload} ->
        markdown = payload[:markdown] || payload["markdown"] || ""

        Result.success(job, %{
          final_url: payload[:final_url] || payload["final_url"] || job.url,
          title: payload[:title] || payload["title"] || Markdown.title(markdown),
          markdown: markdown,
          status_code: payload[:status_code] || payload["status_code"],
          agent_id: agent["id"],
          duration_ms: elapsed_ms(started_at),
          word_count: Markdown.word_count(markdown)
        })

      {:error, error} ->
        Result.failure(job, error, %{
          agent_id: agent["id"],
          duration_ms: elapsed_ms(started_at)
        })
    end
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
