defmodule GSMLG.AdminWeb.BrowserAPI.ArtifactDownload do
  @moduledoc false

  import Plug.Conn

  alias GSMLG.AdminWeb.BrowserAPI.{ByteRange, Response}
  alias GSMLG.Browser
  alias GSMLG.Browser.Error

  @chunk_size 65_536
  @media_type ~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\z}i

  def send(conn, actor, artifact_id) do
    case Browser.open_artifact(actor, artifact_id) do
      {:ok, %{size: size} = artifact} when is_integer(size) and size >= 0 ->
        serve(conn, actor, artifact_id, artifact)

      {:error, %Error{} = error} ->
        Response.from_browser(conn, error)

      _invalid ->
        internal_error(conn)
    end
  end

  defp serve(conn, _actor, _artifact_id, %{size: 0} = artifact) do
    case ByteRange.parse(get_req_header(conn, "range"), 0) do
      :full -> conn |> artifact_headers(artifact) |> send_resp(200, "")
      :invalid -> invalid_range(conn, artifact)
    end
  end

  defp serve(conn, actor, artifact_id, artifact) do
    case ByteRange.parse(get_req_header(conn, "range"), artifact.size) do
      :full -> stream(conn, actor, artifact_id, artifact, 0, artifact.size - 1, 200)
      {:ok, {first, last}} -> stream(conn, actor, artifact_id, artifact, first, last, 206)
      :invalid -> invalid_range(conn, artifact)
    end
  end

  defp stream(conn, actor, artifact_id, artifact, first, last, status) do
    [{^first, first_last}] = ByteRange.chunks(first, last, @chunk_size) |> Enum.take(1)

    case read(actor, artifact_id, first, first_last) do
      {:ok, bytes} ->
        conn =
          conn
          |> artifact_headers(artifact)
          |> maybe_content_range(status, first, last, artifact.size)
          |> send_chunked(status)

        case chunk(conn, bytes) do
          {:ok, conn} -> stream_remaining(conn, actor, artifact_id, first_last + 1, last)
          {:error, _client_closed} -> conn
        end

      {:error, %Error{} = error} ->
        Response.from_browser(conn, error)

      _invalid ->
        internal_error(conn)
    end
  end

  defp stream_remaining(conn, _actor, _artifact_id, next, last) when next > last, do: conn

  defp stream_remaining(conn, actor, artifact_id, next, last) do
    next
    |> ByteRange.chunks(last, @chunk_size)
    |> Enum.reduce_while(conn, fn {first, chunk_last}, conn ->
      case read(actor, artifact_id, first, chunk_last) do
        {:ok, bytes} ->
          case chunk(conn, bytes) do
            {:ok, conn} -> {:cont, conn}
            {:error, _client_closed} -> {:halt, conn}
          end

        _error ->
          exit({:shutdown, :browser_artifact_read_failed})
      end
    end)
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

  defp artifact_headers(conn, artifact) do
    conn
    |> put_resp_header("content-type", media_type(artifact.content_type))
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-disposition", content_disposition(artifact.filename))
    |> Response.security_headers()
  end

  defp maybe_content_range(conn, 206, first, last, size),
    do: put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{size}")

  defp maybe_content_range(conn, _status, _first, _last, _size), do: conn

  defp invalid_range(conn, artifact) do
    conn
    |> artifact_headers(artifact)
    |> put_resp_header("content-range", "bytes */#{artifact.size}")
    |> Response.error(
      416,
      "artifact",
      "invalid_range",
      "The requested Browser artifact range is invalid.",
      false,
      "correct_request"
    )
  end

  defp internal_error(conn) do
    Response.error(
      conn,
      500,
      "internal",
      "browser_internal_error",
      "The Browser operation could not be completed.",
      false,
      nil
    )
  end

  defp media_type(value) when is_binary(value) do
    if String.valid?(value) and Regex.match?(@media_type, value),
      do: String.downcase(value),
      else: "application/octet-stream"
  end

  defp media_type(_value), do: "application/octet-stream"

  defp content_disposition(filename) do
    filename =
      if is_binary(filename) and String.valid?(filename),
        do: Path.basename(filename),
        else: "artifact"

    fallback =
      filename
      |> String.to_charlist()
      |> Enum.map_join(fn
        character when character in 0x20..0x7E and character not in [?", ?\\] -> <<character>>
        _unsafe -> "_"
      end)
      |> case do
        "" -> "artifact"
        safe -> safe
      end

    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    ~s(attachment; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end
end
