defmodule GSMLG.Scout.Agent.Executor do
  @moduledoc """
  Executes a single fetch job through Lightpanda.
  """

  alias GSMLG.Scout.Agent.LightpandaPool
  alias GSMLG.Scout.Fetch.{Job, Result}
  alias GSMLG.Scout.Markdown
  alias GSMLG.Scout.Security
  alias GSMLG.Scout.Settings

  def fetch(%Job{} = job) do
    started_at = System.monotonic_time(:millisecond)
    settings = Settings.get()
    agent = settings["agent"]

    opts =
      job.browser
      |> Map.put("timeout_ms", job.timeout_ms)
      |> Map.put("lightpanda_path", agent["lightpanda_path"])

    with {:ok, payload} <- LightpandaPool.fetch(job.url, opts),
         {:ok, final_url} <- validated_final_url(payload, job.url, settings) do
      markdown = payload[:markdown] || payload["markdown"] || ""

      Result.success(job, %{
        final_url: final_url,
        title: payload[:title] || payload["title"] || Markdown.title(markdown),
        markdown: markdown,
        status_code: payload[:status_code] || payload["status_code"],
        agent_id: agent["id"],
        duration_ms: elapsed_ms(started_at),
        word_count: Markdown.word_count(markdown)
      })
    else
      {:error, error} ->
        Result.failure(job, error, %{
          agent_id: agent["id"],
          duration_ms: elapsed_ms(started_at)
        })
    end
  end

  defp validated_final_url(payload, guarded_url, settings) do
    final_url = payload[:final_url] || payload["final_url"] || guarded_url

    case Security.validate_url(final_url, settings) do
      :ok ->
        {:ok, final_url}

      {:error, error} ->
        {:error,
         %{
           error
           | message: "final URL failed Scout security validation: #{error.message}",
             retryable: false
         }}
    end
  end

  defp elapsed_ms(started_at), do: System.monotonic_time(:millisecond) - started_at
end
