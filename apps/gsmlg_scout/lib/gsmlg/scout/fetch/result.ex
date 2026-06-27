defmodule GSMLG.Scout.Fetch.Result do
  @moduledoc """
  Result payload emitted by a Scout Agent.
  """

  alias GSMLG.Scout.Fetch.Job

  @keys ~w(job_id ok url final_url title markdown status_code agent_id duration_ms word_count error)

  defstruct [
    :job_id,
    :ok,
    :url,
    :final_url,
    :title,
    :markdown,
    :status_code,
    :agent_id,
    :duration_ms,
    :word_count,
    :error
  ]

  def success(%Job{} = job, attrs) do
    %__MODULE__{
      job_id: job.job_id,
      ok: true,
      url: job.url,
      final_url: attrs[:final_url] || attrs["final_url"] || job.url,
      title: attrs[:title] || attrs["title"],
      markdown: attrs[:markdown] || attrs["markdown"] || "",
      status_code: attrs[:status_code] || attrs["status_code"],
      agent_id: attrs[:agent_id] || attrs["agent_id"],
      duration_ms: attrs[:duration_ms] || attrs["duration_ms"],
      word_count: attrs[:word_count] || attrs["word_count"]
    }
  end

  def failure(%Job{} = job, error, attrs \\ %{}) do
    %__MODULE__{
      job_id: job.job_id,
      ok: false,
      url: job.url,
      agent_id: attrs[:agent_id] || attrs["agent_id"],
      duration_ms: attrs[:duration_ms] || attrs["duration_ms"],
      error: normalize_error(error)
    }
  end

  def from_map(map) when is_map(map) do
    attrs =
      Enum.reduce(map, %{}, fn {key, value}, acc ->
        case normalize_key(key) do
          nil -> acc
          normalized -> Map.put(acc, normalized, value)
        end
      end)

    struct!(__MODULE__, attrs)
  end

  def to_map(%__MODULE__{} = result) do
    result
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_error(error) when is_map(error) do
    %{
      type: to_string(error[:type] || error["type"] || "fetch_failed"),
      message: to_string(error[:message] || error["message"] || "Fetch failed"),
      retryable: error[:retryable] || error["retryable"] || false
    }
  end

  defp normalize_error(error) do
    %{type: "fetch_failed", message: inspect(error), retryable: false}
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key) and key in @keys, do: String.to_existing_atom(key)
  defp normalize_key(_key), do: nil
end
