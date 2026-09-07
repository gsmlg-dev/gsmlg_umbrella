defmodule GSMLG.AdminWeb.Plugs.BrowserArtifactUploadIngress do
  @moduledoc false

  import Plug.Conn

  alias GSMLG.Browser.ArtifactService

  @default_chunk_size 65_536
  @token ~r/\A[A-Za-z0-9_-]{43}\z/
  @sha256 ~r/\A[0-9a-f]{64}\z/
  @media_type ~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\z}i

  def init(opts), do: opts

  def call(%{method: "PUT", path_info: ["browser-artifact-uploads", artifact_id]} = conn, opts) do
    service = Keyword.get(opts, :service, ArtifactService)
    chunk_size = Keyword.get(opts, :chunk_size, @default_chunk_size)

    with "" <- conn.query_string,
         {:ok, artifact_id} <- uuid(artifact_id),
         {:ok, token} <- upload_token(conn),
         {:ok, headers, content_length} <- upload_headers(conn, token),
         true <- content_length <= max_artifact_bytes(),
         {:ok, handle} <- service.begin_upload(artifact_id, token, headers) do
      stream_claimed(conn, service, handle, content_length, bounded_chunk_size(chunk_size))
    else
      {:error, :authentication_required} -> empty_response(conn, 401)
      {:error, :invalid_request} -> empty_response(conn, 400)
      false -> empty_response(conn, 413)
      {:error, _begin_rejected} -> empty_response(conn, 401)
      _invalid -> empty_response(conn, 400)
    end
  end

  def call(conn, _opts), do: conn

  defp stream_claimed(conn, service, handle, remaining, chunk_size) do
    try do
      stream(conn, service, handle, remaining, chunk_size)
    catch
      kind, reason ->
        _ = service.abort_upload(handle)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp stream(conn, service, handle, remaining, chunk_size) do
    read_length = min(chunk_size, max(remaining + 1, 1))

    case read_body(conn, length: read_length, read_length: read_length, read_timeout: 15_000) do
      {:more, bytes, conn} ->
        continue_stream(conn, service, handle, bytes, remaining, chunk_size, true)

      {:ok, bytes, conn} ->
        continue_stream(conn, service, handle, bytes, remaining, chunk_size, false)

      {:error, _reason} ->
        _ = service.abort_upload(handle)
        empty_response(conn, 400)
    end
  end

  defp continue_stream(conn, service, handle, bytes, remaining, chunk_size, more?)
       when is_binary(bytes) do
    received = byte_size(bytes)

    cond do
      received > remaining ->
        _ = service.abort_upload(handle)
        empty_response(conn, 400)

      bytes != "" and service.write_upload_chunk(handle, bytes) != :ok ->
        _ = service.abort_upload(handle)
        empty_response(conn, 503)

      more? ->
        stream(conn, service, handle, remaining - received, chunk_size)

      received != remaining ->
        _ = service.abort_upload(handle)
        empty_response(conn, 400)

      true ->
        finish(conn, service, handle)
    end
  end

  defp finish(conn, service, handle) do
    case service.finish_upload(handle) do
      {:ok, _artifact} ->
        empty_response(conn, 204)

      {:error, _reason} ->
        _ = service.abort_upload(handle)
        empty_response(conn, 422)

      _invalid ->
        _ = service.abort_upload(handle)
        empty_response(conn, 503)
    end
  end

  defp upload_token(conn) do
    case get_req_header(conn, "x-browser-upload-token") do
      [token] when is_binary(token) and byte_size(token) == 43 ->
        if Regex.match?(@token, token), do: {:ok, token}, else: {:error, :authentication_required}

      _missing_or_duplicate ->
        {:error, :authentication_required}
    end
  end

  defp upload_headers(conn, token) do
    with [content_type] <- get_req_header(conn, "content-type"),
         true <- valid_content_type?(content_type),
         [content_length] <- get_req_header(conn, "content-length"),
         {:ok, parsed_length} <- nonnegative_integer(content_length),
         [sha256] <- get_req_header(conn, "x-content-sha256"),
         true <- Regex.match?(@sha256, sha256),
         [] <- get_req_header(conn, "content-encoding"),
         [] <- get_req_header(conn, "transfer-encoding") do
      {:ok,
       %{
         "content-type" => content_type,
         "content-length" => content_length,
         "x-content-sha256" => sha256,
         "x-browser-upload-token" => token
       }, parsed_length}
    else
      _invalid -> {:error, :invalid_request}
    end
  end

  defp uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} when uuid == value -> {:ok, uuid}
      _invalid -> {:error, :invalid_request}
    end
  end

  defp nonnegative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _invalid -> {:error, :invalid_request}
    end
  end

  defp valid_content_type?(value),
    do: is_binary(value) and byte_size(value) in 1..255 and Regex.match?(@media_type, value)

  defp bounded_chunk_size(value) when is_integer(value) and value in 1..262_144, do: value
  defp bounded_chunk_size(_value), do: @default_chunk_size

  defp max_artifact_bytes,
    do: Application.get_env(:gsmlg_browser, :max_artifact_bytes, 104_857_600)

  defp empty_response(conn, status) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, "")
    |> halt()
  end
end
