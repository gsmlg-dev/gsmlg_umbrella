defmodule GSMLG.BrowserAgent.WorkflowArtifacts do
  @moduledoc false

  alias GSMLG.BrowserAgent.{ArtifactOutbox, Journal}
  alias GSMLG.Commander.Protocol.ArtifactManifest

  @formats %{
    "report.markdown" => {"text/markdown", "report.md"},
    "report.html" => {"text/html", "report.html"},
    "report.json" => {"application/json", "report.json"},
    "sources.json" => {"application/json", "sources.json"},
    "screenshot.png" => {"image/png", "report.png"}
  }

  @doc false
  def artifact_id(execution_id, format) do
    <<a::32, b::16, c::16, d::16, e::48, _rest::binary>> =
      :crypto.hash(:sha256, execution_id <> ":" <> format)

    [hex(<<a::32>>), hex(<<b::16>>), hex(<<c::16>>), hex(<<d::16>>), hex(<<e::48>>)]
    |> Enum.join("-")
  end

  def produce(journal, state_dir, checkpoint, opts \\ []) do
    Enum.reduce_while(checkpoint.output_formats, {:ok, []}, fn format, {:ok, manifests} ->
      with {:ok, manifest} <- produce_one(journal, state_dir, checkpoint, format, opts),
           {:ok, _decoded} <-
             ArtifactManifest.decode(Map.put(manifest, "type", "artifact.manifest")) do
        {:cont, {:ok, [manifest | manifests]}}
      else
        _error -> {:halt, {:error, :workflow_artifact_failed}}
      end
    end)
    |> case do
      {:ok, manifests} -> {:ok, Enum.reverse(manifests)}
      error -> error
    end
  end

  defp produce_one(journal, _state_dir, checkpoint, "screenshot.png", _opts) do
    existing_manifest(journal, artifact_id(checkpoint.remote_execution_id, "screenshot.png"))
  end

  defp produce_one(journal, state_dir, checkpoint, format, opts) do
    with {:ok, content} <- content(format, checkpoint),
         {mime, filename} <- Map.fetch!(@formats, format),
         artifact_id = artifact_id(checkpoint.remote_execution_id, format),
         attrs = %{
           "artifact_id" => artifact_id,
           "job_id" => checkpoint.central_job_id,
           "kind" => format,
           "mime" => mime,
           "filename" => filename,
           "metadata" => %{"remote_execution_id" => checkpoint.remote_execution_id}
         } do
      put_or_replay(journal, state_dir, attrs, content, opts)
    end
  end

  defp put_or_replay(journal, state_dir, attrs, content, opts) do
    case ArtifactOutbox.put(journal, state_dir, attrs, content, opts) do
      {:ok, manifest} -> {:ok, manifest}
      {:error, :artifact_exists} -> existing_manifest(journal, attrs["artifact_id"])
      error -> error
    end
  end

  defp content("report.markdown", checkpoint) do
    fetch_binary(
      Map.get(checkpoint.result, :markdown) || get_in(checkpoint, [:last_observation, :markdown])
    )
  end

  defp content("report.html", checkpoint) do
    case Map.get(checkpoint.result, :html) do
      html when is_binary(html) and html != "" -> {:ok, html}
      _missing -> content("report.markdown", checkpoint) |> render_html()
    end
  end

  defp content("report.json", checkpoint), do: encode_json(checkpoint.result)

  defp content("sources.json", checkpoint) do
    sources =
      Map.get(checkpoint.result, :sources) ||
        %{
          "source_video" => Map.get(checkpoint.result, "source_video"),
          "evidence" => Map.get(checkpoint.result, "evidence", [])
        }

    encode_json(sources)
  end

  defp content(_format, _checkpoint), do: {:error, :unsupported_artifact_format}

  defp fetch_binary(value) when is_binary(value) and value != "", do: {:ok, value}
  defp fetch_binary(_value), do: {:error, :artifact_content_missing}

  defp encode_json(value), do: {:ok, JSON.encode!(value)}

  defp render_html({:ok, markdown}) do
    escaped =
      markdown
      |> String.replace("&", "&amp;")
      |> String.replace("<", "&lt;")
      |> String.replace(">", "&gt;")

    {:ok, "<pre>#{escaped}</pre>"}
  end

  defp render_html(error), do: error

  defp hex(value), do: Base.encode16(value, case: :lower)

  defp existing_manifest(journal, artifact_id) do
    case Journal.get(journal, :artifact_outbox, artifact_id) do
      {:ok, %{manifest: manifest}} -> {:ok, manifest}
      _missing -> {:error, :workflow_artifact_failed}
    end
  end
end
