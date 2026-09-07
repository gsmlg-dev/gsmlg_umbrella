defmodule GSMLG.BrowserAgent.ArtifactTransferTest do
  use ExUnit.Case, async: true

  alias GSMLG.BrowserAgent.{
    ArtifactOutbox,
    ArtifactTransfer,
    Capability,
    Journal,
    RequestDedup,
    Settings
  }

  alias GSMLG.Commander.CapabilityRegistry
  alias GSMLG.Commander.Protocol.RPCRequest

  @moduletag :tmp_dir
  @artifact_id "11111111-1111-4111-8111-111111111111"
  @execution_id "22222222-2222-4222-8222-222222222222"
  @job_id "33333333-3333-4333-8333-333333333333"
  @session_id "44444444-4444-4444-8444-444444444444"
  @remote_session_id "55555555-5555-4555-8555-555555555555"

  setup %{tmp_dir: tmp_dir} do
    dets = String.to_atom("artifact_transfer_#{System.unique_integer([:positive])}")

    {:ok, journal} =
      Journal.start_link(name: nil, path: Path.join(tmp_dir, "artifacts.dets"), dets_name: dets)

    on_exit(fn ->
      if Process.alive?(journal), do: GenServer.stop(journal)
      _ = :dets.close(dets)
    end)

    %{journal: journal, state_dir: tmp_dir}
  end

  test "inline fetch is identity-bound and respects the encoded 128 KiB application ceiling",
       ctx do
    manifest = put_artifact(ctx, "safe report")
    payload = identity_payload(manifest)

    assert {:ok, result} =
             ArtifactTransfer.dispatch("artifact.fetch_inline", payload, ctx.journal)

    assert Base.decode64!(result["content_base64"]) == "safe report"
    assert byte_size(JSON.encode!(result)) <= 131_072

    assert {:error, :artifact_identity_mismatch} =
             ArtifactTransfer.dispatch(
               "artifact.fetch_inline",
               %{payload | "central_job_id" => "wrong-job"},
               ctx.journal
             )

    large = String.duplicate("x", 100_000)
    large_manifest = put_artifact(ctx, large, "33333333-3333-4333-8333-333333333333")

    assert {:error, :artifact_inline_too_large} =
             ArtifactTransfer.dispatch(
               "artifact.fetch_inline",
               identity_payload(large_manifest),
               ctx.journal
             )
  end

  test "signed upload is HTTPS/allowed-origin/no-redirect and the URL is never journaled", ctx do
    manifest = put_artifact(ctx, "upload me")
    signed_url = "https://uploads.example.test/object"
    parent = self()

    transport = fn url, content, opts ->
      send(parent, {:uploaded, url, content, opts})
      {:ok, %{status: 200, redirects: 0}}
    end

    required_headers = %{
      "content-type" => "text/markdown",
      "content-length" => "9",
      "x-content-sha256" => manifest["sha256"],
      "x-browser-upload-token" => "NEVER-PERSIST"
    }

    payload =
      identity_payload(manifest)
      |> Map.put("upload_url", signed_url)
      |> Map.put("required_headers", required_headers)

    opts = [allowed_upload_origins: ["https://uploads.example.test"], transport: transport]

    assert {:ok, %{"status" => "uploaded"}} =
             ArtifactTransfer.dispatch("artifact.upload", payload, ctx.journal, opts)

    assert_receive {:uploaded, ^signed_url, "upload me", upload_opts}
    assert upload_opts[:follow_redirects] == false
    assert Map.new(upload_opts[:headers]) == required_headers

    refute inspect(Journal.list(ctx.journal, :artifact_outbox)) =~ "NEVER-PERSIST"

    request = %RPCRequest{
      protocol_version: 1,
      request_id: "44444444-4444-4444-8444-444444444444",
      capability: "browser.control",
      capability_version: 1,
      operation: "artifact.upload",
      idempotency_key: "artifact-upload-token-redaction",
      deadline_at: "2026-09-06T01:00:00Z",
      payload: payload
    }

    {:ok, generation} = RequestDedup.begin_generation(ctx.journal)
    assert :execute = RequestDedup.claim(ctx.journal, request, generation)
    refute inspect(Journal.list(ctx.journal, :request_dedup)) =~ "NEVER-PERSIST"

    assert {:error, :artifact_upload_origin_not_allowed} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               %{payload | "upload_url" => "https://evil.test/object"},
               ctx.journal,
               opts
             )

    assert {:error, :invalid_artifact_upload_url} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               %{payload | "upload_url" => "https://uploads.example.test/object?token=secret"},
               ctx.journal,
               opts
             )

    assert {:error, :invalid_artifact_upload_headers} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               put_in(payload, ["required_headers", "x-extra"], "injected"),
               ctx.journal,
               opts
             )

    for invalid_headers <- [
          Map.delete(required_headers, "content-length"),
          %{required_headers | "content-type" => "application/octet-stream"},
          %{required_headers | "content-length" => "999"},
          %{required_headers | "x-content-sha256" => String.duplicate("0", 64)}
        ] do
      assert {:error, :invalid_artifact_upload_headers} =
               ArtifactTransfer.dispatch(
                 "artifact.upload",
                 %{payload | "required_headers" => invalid_headers},
                 ctx.journal,
                 opts
               )
    end

    assert {:error, :invalid_artifact_upload_headers} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               put_in(
                 payload,
                 ["required_headers", "x-browser-upload-token"],
                 "token\r\ninjected: true"
               ),
               ctx.journal,
               opts
             )

    assert {:error, :invalid_artifact_upload_url} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               %{payload | "upload_url" => "https://user:password@uploads.example.test/object"},
               ctx.journal,
               opts
             )

    redirecting = fn _url, _content, _opts -> {:ok, %{status: 307, redirects: 1}} end

    assert {:error, :artifact_upload_redirected} =
             ArtifactTransfer.dispatch(
               "artifact.upload",
               payload,
               ctx.journal,
               Keyword.put(opts, :transport, redirecting)
             )
  end

  test "matching ACK leaves a durable idempotent tombstone and mismatches never prune", ctx do
    manifest = put_artifact(ctx, "ack me")
    payload = identity_payload(manifest) |> Map.put("sha256", manifest["sha256"])

    assert {:error, :artifact_ack_mismatch} =
             ArtifactTransfer.dispatch(
               "artifact.ack",
               %{payload | "sha256" => String.duplicate("0", 64)},
               ctx.journal
             )

    assert [_manifest] = ArtifactOutbox.pending(ctx.journal)

    assert {:ok,
            %{
              "central_job_id" => @job_id,
              "remote_execution_id" => @execution_id,
              "artifact_id" => @artifact_id,
              "sha256" => sha256
            }} =
             ArtifactTransfer.dispatch("artifact.ack", payload, ctx.journal)

    assert sha256 == manifest["sha256"]

    assert [] = ArtifactOutbox.pending(ctx.journal)

    assert {:ok,
            %{
              "central_job_id" => @job_id,
              "remote_execution_id" => @execution_id,
              "artifact_id" => @artifact_id,
              "sha256" => ^sha256
            }} =
             ArtifactTransfer.dispatch("artifact.ack", payload, ctx.journal)

    assert {:ok, tombstone} = Journal.get(ctx.journal, :artifact_ack_tombstone, @artifact_id)
    assert tombstone.sha256 == manifest["sha256"]
    refute Map.has_key?(tombstone, :upload_url)
  end

  test "session-owned fetch and ACK are bound to both central and remote session IDs", ctx do
    manifest = put_session_artifact(ctx, "png")

    payload = %{
      "artifact_id" => manifest["artifact_id"],
      "central_session_id" => @session_id,
      "remote_session_id" => @remote_session_id
    }

    assert {:ok, %{"content_base64" => encoded}} =
             ArtifactTransfer.dispatch("artifact.fetch_inline", payload, ctx.journal)

    assert Base.decode64!(encoded) == "png"

    assert {:error, :artifact_identity_mismatch} =
             ArtifactTransfer.dispatch(
               "artifact.fetch_inline",
               %{payload | "remote_session_id" => "66666666-6666-4666-8666-666666666666"},
               ctx.journal
             )

    ack = Map.put(payload, "sha256", manifest["sha256"])
    assert {:ok, ^ack} = ArtifactTransfer.dispatch("artifact.ack", ack, ctx.journal)
    assert {:ok, ^ack} = ArtifactTransfer.dispatch("artifact.ack", ack, ctx.journal)
  end

  test "failed upload is not reissued with one-use credentials and a fresh capability can retry",
       ctx do
    manifest = put_artifact(ctx, "upload me")
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    transport = fn _url, _content, _opts ->
      Agent.get_and_update(attempts, fn
        0 -> {{:error, :connection_lost}, 1}
        count -> {{:ok, %{status: 200, redirects: 0}}, count + 1}
      end)
    end

    {:ok, registry} = CapabilityRegistry.start_link(name: nil)

    settings =
      Settings.load!(
        %{
          enabled: true,
          manager_url: "http://127.0.0.1:8080",
          manager_token_env: "IGNORED",
          state_dir: ctx.state_dir,
          security: %{allowed_upload_origins: ["https://uploads.example.test"]}
        },
        manager_token: "secret"
      )

    {:ok, capability} =
      Capability.start_link(
        name: nil,
        registry: registry,
        monitor: self(),
        journal: ctx.journal,
        settings: settings,
        artifact_opts: [
          allowed_upload_origins: settings.allowed_upload_origins,
          transport: transport
        ]
      )

    headers = %{
      "content-type" => manifest["mime"],
      "content-length" => Integer.to_string(manifest["size"]),
      "x-content-sha256" => manifest["sha256"],
      "x-browser-upload-token" => "one-use-token-1"
    }

    payload =
      identity_payload(manifest)
      |> Map.put("upload_url", "https://uploads.example.test/object-1")
      |> Map.put("required_headers", headers)

    first = rpc(payload, "55555555-5555-4555-8555-555555555551", "upload-generation-1")

    assert {:error, %{code: "artifact_transport_failed", retryable: true}} =
             GenServer.call(capability, {:rpc, first})

    assert {:error, %{code: "artifact_transport_failed", retryable: true}} =
             GenServer.call(capability, {:rpc, first})

    assert Agent.get(attempts, & &1) == 1
    assert [_retained] = ArtifactOutbox.pending(ctx.journal)

    fresh_headers = %{headers | "x-browser-upload-token" => "one-use-token-2"}

    fresh_payload = %{
      payload
      | "upload_url" => "https://uploads.example.test/object-2",
        "required_headers" => fresh_headers
    }

    fresh = rpc(fresh_payload, "55555555-5555-4555-8555-555555555552", "upload-generation-2")

    assert {:ok, %{"status" => "uploaded"}} = GenServer.call(capability, {:rpc, fresh})
    assert Agent.get(attempts, & &1) == 2
    assert [_retained_until_ack] = ArtifactOutbox.pending(ctx.journal)

    GenServer.stop(capability)
    GenServer.stop(registry)
    Agent.stop(attempts)
  end

  defp put_artifact(ctx, content, artifact_id \\ @artifact_id) do
    attrs = %{
      "artifact_id" => artifact_id,
      "job_id" => @job_id,
      "kind" => "report.markdown",
      "mime" => "text/markdown",
      "filename" => "report.md",
      "metadata" => %{"remote_execution_id" => @execution_id}
    }

    {:ok, manifest} = ArtifactOutbox.put(ctx.journal, ctx.state_dir, attrs, content)
    manifest
  end

  defp put_session_artifact(ctx, content) do
    attrs = %{
      "artifact_id" => @artifact_id,
      "session_id" => @session_id,
      "kind" => "screenshot.png",
      "mime" => "image/png",
      "filename" => "screenshot.png",
      "metadata" => %{"remote_session_id" => @remote_session_id}
    }

    {:ok, manifest} = ArtifactOutbox.put(ctx.journal, ctx.state_dir, attrs, content)
    manifest
  end

  defp identity_payload(manifest) do
    %{
      "artifact_id" => manifest["artifact_id"],
      "central_job_id" => manifest["job_id"],
      "remote_execution_id" => manifest["metadata"]["remote_execution_id"]
    }
  end

  defp rpc(payload, request_id, idempotency_key) do
    %RPCRequest{
      protocol_version: 1,
      request_id: request_id,
      capability: "browser.control",
      capability_version: 1,
      operation: "artifact.upload",
      idempotency_key: idempotency_key,
      deadline_at: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_iso8601(),
      payload: payload
    }
  end
end
