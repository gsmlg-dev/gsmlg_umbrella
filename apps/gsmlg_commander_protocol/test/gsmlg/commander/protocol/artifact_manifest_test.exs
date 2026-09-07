defmodule GSMLG.Commander.Protocol.ArtifactManifestTest do
  use ExUnit.Case, async: true

  alias GSMLG.Commander.Protocol.{ArtifactManifest, Envelope}

  @artifact_id "323e4567-e89b-12d3-a456-426614174000"
  @execution_id "223e4567-e89b-12d3-a456-426614174000"
  @job_id "423e4567-e89b-42d3-a456-426614174000"
  @session_id "523e4567-e89b-42d3-a456-426614174000"
  @remote_session_id "623e4567-e89b-42d3-a456-426614174000"

  test "strictly round-trips a workflow-owned artifact manifest" do
    wire = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "job_id" => @job_id,
      "kind" => "report.markdown",
      "mime" => "text/markdown",
      "filename" => "report.md",
      "size" => 42,
      "sha256" => String.duplicate("a", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{
        "workflow" => "gemini.deep_research/v1",
        "remote_execution_id" => @execution_id
      }
    }

    assert {:ok, %ArtifactManifest{} = manifest} = Envelope.decode(wire)
    assert {:ok, ^wire} = Envelope.encode(manifest)
    assert manifest.job_id == @job_id
  end

  test "rejects unknown fields and malformed integrity metadata" do
    base = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "job_id" => @job_id,
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "size" => 1,
      "sha256" => String.duplicate("b", 64),
      "transfer_mode" => "inline",
      "metadata" => %{}
    }

    assert {:error, %{code: "unknown_fields"}} = Envelope.decode(Map.put(base, "path", "/tmp/x"))
    assert {:error, %{code: "invalid_sha256"}} = Envelope.decode(%{base | "sha256" => "bad"})
  end

  test "strictly round-trips a session-owned artifact manifest" do
    wire = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "session_id" => @session_id,
      "kind" => "download",
      "mime" => "application/octet-stream",
      "filename" => "result.bin",
      "size" => 42,
      "sha256" => String.duplicate("c", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{"remote_session_id" => @remote_session_id}
    }

    assert {:ok, %ArtifactManifest{job_id: nil, session_id: @session_id} = manifest} =
             Envelope.decode(wire)

    assert {:ok, ^wire} = Envelope.encode(manifest)
  end

  test "requires exactly one durable artifact owner" do
    base = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "kind" => "screenshot.png",
      "mime" => "image/png",
      "filename" => "screenshot.png",
      "size" => 42,
      "sha256" => String.duplicate("d", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{}
    }

    assert {:error, %{code: "invalid_artifact_owner"}} = Envelope.decode(base)

    assert {:error, %{code: "invalid_artifact_owner"}} =
             Envelope.decode(Map.merge(base, %{"job_id" => @job_id, "session_id" => @session_id}))
  end

  test "browser control advertises artifact transfer operations" do
    assert Enum.take(Envelope.browser_control_operations(), -3) == [
             "artifact.fetch_inline",
             "artifact.upload",
             "artifact.ack"
           ]
  end

  test "kind, MIME, and filename extension are one strict contract" do
    base = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "job_id" => @job_id,
      "kind" => "screenshot.png",
      "mime" => "image/png",
      "filename" => "report.png",
      "size" => 42,
      "sha256" => String.duplicate("a", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{"remote_execution_id" => @execution_id}
    }

    assert {:error, %{code: "invalid_artifact_media"}} =
             Envelope.decode(%{base | "mime" => "text/html"})

    assert {:error, %{code: "invalid_artifact_media"}} =
             Envelope.decode(%{base | "filename" => "report.html"})
  end

  test "download media uses the finite CDP MIME and extension matrix" do
    base = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "session_id" => @session_id,
      "kind" => "download",
      "size" => 42,
      "sha256" => String.duplicate("a", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{"remote_session_id" => @remote_session_id}
    }

    for {mime, extension} <- [
          {"application/octet-stream", ".bin"},
          {"application/pdf", ".pdf"},
          {"application/json", ".json"},
          {"text/html", ".html"},
          {"text/markdown", ".md"},
          {"text/plain", ".txt"},
          {"image/png", ".png"},
          {"image/jpeg", ".jpg"},
          {"image/jpeg", ".jpeg"}
        ] do
      wire = Map.merge(base, %{"mime" => mime, "filename" => "download#{extension}"})

      assert {:ok, %ArtifactManifest{mime: ^mime, filename: "download" <> ^extension}} =
               Envelope.decode(wire)
    end

    for {mime, filename} <- [
          {"application/json", "download.txt"},
          {"application/octet-stream", "download.zip"},
          {"application/zip", "download.bin"}
        ] do
      assert {:error, %{code: "invalid_artifact_media"}} =
               Envelope.decode(Map.merge(base, %{"mime" => mime, "filename" => filename}))
    end
  end

  test "metadata cardinality and encoded size are bounded" do
    base = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "job_id" => @job_id,
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "size" => 42,
      "sha256" => String.duplicate("a", 64),
      "transfer_mode" => "remote_pending",
      "metadata" => %{}
    }

    many = Map.new(1..17, &{"key-#{&1}", &1})
    assert {:error, %{code: "metadata_too_large"}} = Envelope.decode(%{base | "metadata" => many})

    assert {:error, %{code: "metadata_too_large"}} =
             Envelope.decode(%{base | "metadata" => %{"note" => String.duplicate("x", 4_096)}})
  end

  test "job ownership is a UUID" do
    wire = %{
      "type" => "artifact.manifest",
      "protocol_version" => 1,
      "artifact_id" => @artifact_id,
      "job_id" => "central-job-1",
      "kind" => "report.json",
      "mime" => "application/json",
      "filename" => "report.json",
      "size" => 1,
      "sha256" => String.duplicate("b", 64),
      "transfer_mode" => "inline",
      "metadata" => %{}
    }

    assert {:error, %{code: "invalid_uuid"}} = Envelope.decode(wire)
  end
end
