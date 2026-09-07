defmodule GSMLG.BrowserAgent.ArtifactTransfer do
  @moduledoc "Strict remote artifact transfer operations; signed URLs never enter durable state."

  alias GSMLG.BrowserAgent.{ArtifactOutbox, Journal, OriginPolicy}

  @max_wire_bytes 131_072
  @max_raw_inline_bytes 131_072
  @max_upload_bytes 104_857_600
  @job_identity_keys ~w(artifact_id central_job_id remote_execution_id)
  @session_identity_keys ~w(artifact_id central_session_id remote_session_id)
  @upload_header_keys ~w(content-type content-length x-content-sha256 x-browser-upload-token)

  def dispatch(operation, payload, journal, opts \\ [])

  def dispatch("artifact.fetch_inline", payload, journal, opts) when is_map(payload) do
    with {:ok, _identity_keys} <- exact_identity(payload, []),
         {:ok, entry} <- owned_entry(journal, payload),
         {:ok, content} <- ArtifactOutbox.read(journal, payload["artifact_id"]),
         true <-
           byte_size(content) <=
             min(
               Keyword.get(opts, :max_raw_inline_bytes, @max_raw_inline_bytes),
               @max_raw_inline_bytes
             ),
         result = %{
           "artifact_id" => payload["artifact_id"],
           "sha256" => entry.manifest["sha256"],
           "content_base64" => Base.encode64(content)
         },
         true <- encoded_size(result) <= @max_wire_bytes do
      {:ok, result}
    else
      false -> {:error, :artifact_inline_too_large}
      {:error, _reason} = error -> error
    end
  end

  def dispatch("artifact.upload", payload, journal, opts) when is_map(payload) do
    with {:ok, _identity_keys} <- exact_identity(payload, ["upload_url", "required_headers"]),
         {:ok, entry} <- owned_entry(journal, payload),
         {:ok, content} <- ArtifactOutbox.read(journal, payload["artifact_id"]),
         true <- byte_size(content) <= Keyword.get(opts, :max_upload_bytes, @max_upload_bytes),
         :ok <- validate_upload_url(payload["upload_url"], opts),
         {:ok, headers} <- validate_upload_headers(payload["required_headers"], entry.manifest),
         {:ok, response} <- upload(payload["upload_url"], content, headers, opts),
         :ok <- validate_upload_response(response) do
      {:ok, %{"artifact_id" => payload["artifact_id"], "status" => "uploaded"}}
    else
      false -> {:error, :artifact_upload_too_large}
      {:error, _reason} = error -> error
      _invalid -> {:error, :artifact_upload_failed}
    end
  end

  def dispatch("artifact.ack", payload, journal, opts) when is_map(payload) do
    with {:ok, identity_keys} <- exact_identity(payload, ["sha256"]),
         :ok <- validate_ack_identity(journal, payload),
         :ok <- ArtifactOutbox.ack(journal, payload["artifact_id"], payload["sha256"], opts) do
      {:ok, Map.take(payload, identity_keys ++ ["sha256"])}
    end
  end

  def dispatch(operation, _payload, _journal, _opts)
      when operation in ["artifact.fetch_inline", "artifact.upload", "artifact.ack"],
      do: {:error, :invalid_artifact_request}

  def dispatch(_operation, _payload, _journal, _opts),
    do: {:error, :artifact_operation_not_supported}

  defp owned_entry(journal, payload) do
    case Journal.get(journal, :artifact_outbox, payload["artifact_id"]) do
      {:ok, %{manifest: manifest} = entry} ->
        if artifact_owner_matches?(manifest, payload),
          do: {:ok, entry},
          else: {:error, :artifact_identity_mismatch}

      :error ->
        {:error, :artifact_not_found}
    end
  end

  defp validate_ack_identity(journal, payload) do
    case owned_entry(journal, payload) do
      {:ok, _entry} ->
        :ok

      {:error, :artifact_not_found} ->
        case Journal.get(journal, :artifact_ack_tombstone, payload["artifact_id"]) do
          {:ok, tombstone} ->
            if tombstone_owner_matches?(tombstone, payload),
              do: :ok,
              else: {:error, :artifact_identity_mismatch}

          :error ->
            {:error, :artifact_not_found}
        end

      error ->
        error
    end
  end

  defp validate_upload_url(url, opts) when is_binary(url) and byte_size(url) in 1..8_192 do
    allowed = Keyword.get(opts, :allowed_upload_origins, [])

    with %URI{scheme: "https", host: host, userinfo: nil, query: nil, fragment: nil} = uri <-
           URI.parse(url),
         true <- is_binary(host) and host != "",
         {:ok, origin} <- OriginPolicy.origin(URI.to_string(%{uri | path: nil, query: nil})),
         true <- origin in allowed do
      :ok
    else
      %URI{scheme: scheme} when scheme != "https" -> {:error, :artifact_upload_https_required}
      %URI{query: query} when not is_nil(query) -> {:error, :invalid_artifact_upload_url}
      %URI{userinfo: userinfo} when not is_nil(userinfo) -> {:error, :invalid_artifact_upload_url}
      _invalid -> {:error, :artifact_upload_origin_not_allowed}
    end
  end

  defp validate_upload_url(_url, _opts), do: {:error, :invalid_artifact_upload_url}

  defp validate_upload_headers(headers, manifest) when is_map(headers) do
    expected = %{
      "content-type" => manifest["mime"],
      "content-length" => Integer.to_string(manifest["size"]),
      "x-content-sha256" => manifest["sha256"]
    }

    token = headers["x-browser-upload-token"]

    valid? =
      Enum.sort(Map.keys(headers)) == Enum.sort(@upload_header_keys) and
        Map.take(headers, Map.keys(expected)) == expected and safe_header_value?(token, 512) and
        Enum.all?(headers, fn {name, value} ->
          name in @upload_header_keys and safe_header_value?(value, 1_024)
        end)

    if valid?,
      do: {:ok, Enum.map(@upload_header_keys, &{&1, headers[&1]})},
      else: {:error, :invalid_artifact_upload_headers}
  end

  defp validate_upload_headers(_headers, _manifest),
    do: {:error, :invalid_artifact_upload_headers}

  defp safe_header_value?(value, max_bytes) do
    is_binary(value) and byte_size(value) in 1..max_bytes and String.valid?(value) and
      not String.contains?(value, ["\r", "\n", <<0>>])
  end

  defp upload(url, content, headers, opts) do
    transport_opts = [
      follow_redirects: false,
      headers: headers,
      max_response_bytes: 16_384,
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000)
    ]

    case Keyword.get(opts, :transport) do
      transport when is_function(transport, 3) ->
        case transport.(url, content, transport_opts) do
          {:ok, response} -> {:ok, response}
          {:error, _private_reason} -> {:error, :artifact_transport_failed}
          _invalid -> {:error, :artifact_transport_failed}
        end

      _missing ->
        upload_with_finch(url, content, transport_opts, opts)
    end
  rescue
    _exception -> {:error, :artifact_transport_failed}
  catch
    _kind, _reason -> {:error, :artifact_transport_failed}
  end

  defp upload_with_finch(url, content, transport_opts, opts) do
    result =
      GSMLG.BrowserAgent.Backends.CloakBrowser.Transport.Finch.request(
        :put,
        url,
        transport_opts[:headers],
        content,
        finch_name: Keyword.get(opts, :finch_name, GSMLG.BrowserAgent.Finch),
        connect_timeout: transport_opts[:timeout_ms],
        receive_timeout: transport_opts[:timeout_ms],
        max_body_bytes: transport_opts[:max_response_bytes]
      )

    case result do
      {:ok, %{status: status}} -> {:ok, %{status: status, redirects: 0}}
      {:error, _reason} -> {:error, :artifact_transport_failed}
      _invalid -> {:error, :artifact_transport_failed}
    end
  end

  defp validate_upload_response(%{redirects: redirects}) when redirects > 0,
    do: {:error, :artifact_upload_redirected}

  defp validate_upload_response(%{status: status, redirects: 0}) when status in 200..299, do: :ok
  defp validate_upload_response(_response), do: {:error, :artifact_upload_failed}

  defp exact_keys(map, keys) do
    if Enum.sort(Map.keys(map)) == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_artifact_request}
  end

  defp exact_identity(payload, extra) do
    cond do
      exact_keys(payload, @job_identity_keys ++ extra) == :ok ->
        {:ok, @job_identity_keys}

      exact_keys(payload, @session_identity_keys ++ extra) == :ok ->
        {:ok, @session_identity_keys}

      true ->
        {:error, :invalid_artifact_request}
    end
  end

  defp artifact_owner_matches?(%{"job_id" => job_id, "metadata" => metadata}, payload) do
    job_id == payload["central_job_id"] and
      metadata["remote_execution_id"] == payload["remote_execution_id"]
  end

  defp artifact_owner_matches?(%{"session_id" => session_id, "metadata" => metadata}, payload) do
    session_id == payload["central_session_id"] and
      metadata["remote_session_id"] == payload["remote_session_id"]
  end

  defp artifact_owner_matches?(_manifest, _payload), do: false

  defp tombstone_owner_matches?(
         %{central_job_id: job_id, remote_execution_id: remote_id},
         payload
       )
       when is_binary(job_id) and is_binary(remote_id) do
    job_id == payload["central_job_id"] and remote_id == payload["remote_execution_id"]
  end

  defp tombstone_owner_matches?(
         %{central_session_id: session_id, remote_session_id: remote_id},
         payload
       )
       when is_binary(session_id) and is_binary(remote_id) do
    session_id == payload["central_session_id"] and remote_id == payload["remote_session_id"]
  end

  defp tombstone_owner_matches?(_tombstone, _payload), do: false

  defp encoded_size(value), do: value |> JSON.encode!() |> byte_size()
end
