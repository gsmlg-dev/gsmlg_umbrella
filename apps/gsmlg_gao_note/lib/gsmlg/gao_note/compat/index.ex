defmodule GSMLG.GaoNote.Compat.Index do
  @moduledoc "Durable delivery of note_chunking.md requests; external service owns chunks and vectors."
  alias GSMLG.GaoNote.Compat
  alias GSMLG.GaoNote.Compat.Search
  alias GSMLG.GaoNote.Workers.IndexWorker

  def enqueue(note_id) do
    if configured?() do
      case Compat.get_note(note_id) do
        nil -> {:ok, nil}
        note -> %{note_id: note.id, revision: note.revision} |> IndexWorker.new() |> Oban.insert()
      end
    else
      {:ok, nil}
    end
  end

  def deliver(note) do
    if configured?() do
      updated_at = DateTime.to_iso8601(note.updated_at)
      request_id = Ecto.UUID.generate()

      body = %{
        request_id: request_id,
        note: %{id: note.id, title: note.title, content: note.content, updated_at: updated_at},
        embedding: %{model: "BAAI/bge-m3", dimensions: 1024, normalize: true},
        chunking: %{
          profile: "bge-m3-markdown-v1",
          max_tokens: 1024,
          overlap_tokens: 128,
          tokenizer: "xlm-roberta"
        }
      }

      headers = [
        {"content-type", "application/json"},
        {"idempotency-key", "gao-note:#{note.id}:#{updated_at}"}
      ]

      token = Search.config()[:search_token]

      headers =
        if is_binary(token) and token != "",
          do: [{"authorization", "Bearer #{token}"} | headers],
          else: headers

      case GSMLG.GaoNote.Compat.HTTP.post_json(Search.config()[:index_url], headers, body, 65_536) do
        {:ok, %{status: status, body: reply}}
        when status in [200, 202] and byte_size(reply) <= 65_536 ->
          case Jason.decode(reply) do
            {:ok,
             %{
               "request_id" => ^request_id,
               "note_id" => id,
               "updated_at" => ^updated_at,
               "status" => status
             }}
            when id == note.id and status in ["accepted", "completed"] ->
              :ok

            _ ->
              {:error, :invalid_index_acknowledgement}
          end

        {:ok, %{status: status}} when status in [400, 401, 422] ->
          {:cancel, {:index_request_rejected, status}}

        {:ok, %{status: status}} ->
          {:error, {:index_service_error, status}}

        {:error, _} ->
          {:error, :index_service_unavailable}
      end
    else
      {:cancel, :index_disabled}
    end
  end

  defp configured?,
    do: is_binary(Search.config()[:index_url]) and Search.config()[:index_url] != ""
end
