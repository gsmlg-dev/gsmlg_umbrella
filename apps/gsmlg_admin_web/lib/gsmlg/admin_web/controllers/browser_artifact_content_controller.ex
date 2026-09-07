defmodule GSMLG.AdminWeb.BrowserArtifactContentController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.Browser
  alias GSMLG.Browser.Error
  alias GSMLG.GaoNote.ByteRange

  @chunk_size 65_536

  def show(conn, %{"id" => artifact_id}) do
    actor = Guardian.Plug.current_resource(conn)

    with {:ok, stream} <- Browser.open_artifact(actor, artifact_id) do
      serve(conn, actor, artifact_id, stream)
    else
      {:error, %Error{code: "not_found"}} -> not_found(conn)
      {:error, %Error{code: "artifact_not_verified"}} -> not_found(conn)
      {:error, %Error{}} -> service_unavailable(conn)
    end
  end

  defp serve(conn, actor, artifact_id, stream) do
    case ByteRange.parse(get_req_header(conn, "range"), stream.size) do
      :full when stream.size == 0 ->
        conn
        |> artifact_headers(stream)
        |> send_resp(200, "")

      :full ->
        stream_range(conn, actor, artifact_id, stream, 0, stream.size - 1, 200)

      {:ok, {first, last}} ->
        stream_range(conn, actor, artifact_id, stream, first, last, 206)

      :invalid ->
        conn
        |> artifact_headers(stream)
        |> put_resp_header("content-range", "bytes */#{stream.size}")
        |> send_resp(416, "")
    end
  end

  defp stream_range(conn, actor, artifact_id, stream, first, last, status) do
    chunk_last = min(first + @chunk_size - 1, last)

    case read(actor, artifact_id, first, chunk_last) do
      {:ok, bytes} ->
        conn =
          conn
          |> artifact_headers(stream)
          |> maybe_content_range(status, first, last, stream.size)
          |> send_chunked(status)

        with {:ok, conn} <- chunk(conn, bytes) do
          stream_remaining(conn, actor, artifact_id, chunk_last + 1, last)
        else
          {:error, _client_closed} -> conn
        end

      _error ->
        service_unavailable(conn)
    end
  end

  defp stream_remaining(conn, _actor, _artifact_id, next, last) when next > last, do: conn

  defp stream_remaining(conn, actor, artifact_id, next, last) do
    chunk_last = min(next + @chunk_size - 1, last)

    case read(actor, artifact_id, next, chunk_last) do
      {:ok, bytes} ->
        case chunk(conn, bytes) do
          {:ok, conn} -> stream_remaining(conn, actor, artifact_id, chunk_last + 1, last)
          {:error, _client_closed} -> conn
        end

      _error ->
        exit({:shutdown, :browser_artifact_read_failed})
    end
  end

  defp read(actor, artifact_id, first, last) do
    expected = last - first + 1

    case Browser.read_artifact_range(actor, artifact_id, first, last) do
      {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == expected -> {:ok, bytes}
      {:ok, _invalid} -> {:error, :unexpected_chunk_size}
      error -> error
    end
  rescue
    _exception -> {:error, :artifact_read_failed}
  catch
    _kind, _reason -> {:error, :artifact_read_failed}
  end

  defp artifact_headers(conn, stream) do
    encoded_filename = URI.encode(stream.filename, &URI.char_unreserved?/1)

    conn
    |> put_resp_header("content-type", stream.content_type)
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=browser-artifact; filename*=UTF-8''#{encoded_filename}"
    )
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> put_resp_header("x-artifact-sha256", stream.sha256)
  end

  defp maybe_content_range(conn, 206, first, last, size),
    do: put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{size}")

  defp maybe_content_range(conn, _status, _first, _last, _size), do: conn

  defp not_found(conn), do: send_resp(conn, 404, "Not found")
  defp service_unavailable(conn), do: send_resp(conn, 503, "Browser artifact unavailable")
end
