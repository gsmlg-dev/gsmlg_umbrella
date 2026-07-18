defmodule GSMLG.AdminWeb.GaoNoteAttachmentContentController do
  use GSMLG.AdminWeb, :controller

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.ByteRange
  alias GSMLG.Storage
  alias GSMLG.Storage.StorageFile

  @chunk_size 65_536
  @media_type ~r{\A[a-z0-9][a-z0-9!#$&^_.+-]*/[a-z0-9][a-z0-9!#$&^_.+-]*\z}i
  @inline_media_types ~w(
    image/avif
    image/gif
    image/jpeg
    image/png
    image/webp
    text/plain
  )

  defguardp is_hex_digit(character)
            when character in ?0..?9 or character in ?a..?f or character in ?A..?F

  def show(conn, %{"note_id" => note_id, "path" => segments}) do
    with {:ok, path} <- decoded_wildcard_path(conn, segments),
         {:ok, attachment} <- find_attachment(note_id, path),
         %StorageFile{} = file <- attachment.storage_file do
      serve(conn, note_id, attachment.path, attachment.mime, file)
    else
      _not_found -> not_found(conn)
    end
  end

  defp find_attachment(note_id, path) do
    case GaoNote.get_attachment_by_path(note_id, path) do
      {:ok, _attachment} = found ->
        found

      {:error, :not_found} ->
        GaoNote.get_deleted_attachment_by_path(note_id, path)

      {:error, _reason} = error ->
        error
    end
  end

  defp decoded_wildcard_path(conn, segments) when is_list(segments) do
    with true <- valid_raw_wildcard?(conn.request_path),
         true <- segments != [],
         true <- Enum.all?(segments, &(is_binary(&1) and String.valid?(&1))) do
      {:ok, Enum.join(segments, "/")}
    else
      _invalid -> {:error, :not_found}
    end
  end

  defp decoded_wildcard_path(_conn, _segments), do: {:error, :not_found}

  defp valid_raw_wildcard?(request_path) do
    case :binary.split(request_path, "/attachments/") do
      [_prefix, raw_path] when raw_path != "" -> valid_percent_encoding?(raw_path)
      _invalid -> false
    end
  end

  defp valid_percent_encoding?(<<>>), do: true

  defp valid_percent_encoding?(<<"%", first, second, rest::binary>>)
       when is_hex_digit(first) and is_hex_digit(second),
       do: valid_percent_encoding?(rest)

  defp valid_percent_encoding?(<<"%", _rest::binary>>), do: false
  defp valid_percent_encoding?(<<_byte, rest::binary>>), do: valid_percent_encoding?(rest)

  defp serve(conn, note_id, path, mime, %StorageFile{size: size} = file)
       when is_integer(size) and size >= 0 do
    case ByteRange.parse(get_req_header(conn, "range"), size) do
      :full when size == 0 ->
        conn
        |> attachment_headers(path, mime)
        |> send_resp(200, "")

      :full ->
        stream(conn, note_id, path, mime, file, {0, size - 1}, 200)

      {:ok, {first, last}} ->
        stream(conn, note_id, path, mime, file, {first, last}, 206)

      :invalid ->
        conn
        |> attachment_headers(path, mime)
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "")
    end
  end

  defp serve(conn, note_id, path, _mime, _file) do
    log_storage_error(note_id, path, :invalid_size)
    service_unavailable(conn)
  end

  defp stream(conn, note_id, path, mime, file, {first, last}, status) do
    [{^first, first_last}] =
      first
      |> ByteRange.chunks(last, @chunk_size)
      |> Enum.take(1)

    case read_chunk(file, first, first_last) do
      {:ok, bytes} ->
        conn =
          conn
          |> attachment_headers(path, mime)
          |> maybe_put_content_range(status, first, last, file.size)
          |> send_chunked(status)

        case chunk(conn, bytes) do
          {:ok, conn} ->
            stream_remaining(conn, note_id, path, file, first_last + 1, last)

          {:error, _client_closed} ->
            conn
        end

      {:error, reason} ->
        log_storage_error(note_id, path, reason)
        service_unavailable(conn)
    end
  end

  defp stream_remaining(conn, note_id, path, file, next, last) do
    next
    |> ByteRange.chunks(last, @chunk_size)
    |> Enum.reduce_while(conn, fn {first, chunk_last}, conn ->
      case read_chunk(file, first, chunk_last) do
        {:ok, bytes} ->
          case chunk(conn, bytes) do
            {:ok, conn} -> {:cont, conn}
            {:error, _client_closed} -> {:halt, conn}
          end

        {:error, reason} ->
          abort_stream!(note_id, path, reason)
      end
    end)
  end

  defp read_chunk(file, first, last) do
    expected_size = last - first + 1

    try do
      case Storage.read_range(file, first, last) do
        {:ok, bytes} when is_binary(bytes) and byte_size(bytes) == expected_size ->
          {:ok, bytes}

        {:ok, _invalid_bytes} ->
          {:error, :unexpected_chunk_size}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      exception -> {:error, {:exception, Exception.message(exception)}}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp attachment_headers(conn, path, mime) do
    content_type = verified_content_type(mime)

    conn
    |> put_resp_header("content-type", content_type)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("content-disposition", content_disposition(path, content_type))
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp maybe_put_content_range(conn, 206, first, last, size),
    do: put_resp_header(conn, "content-range", "bytes #{first}-#{last}/#{size}")

  defp maybe_put_content_range(conn, _status, _first, _last, _size), do: conn

  defp verified_content_type(content_type) when is_binary(content_type) do
    if String.valid?(content_type) and Regex.match?(@media_type, content_type) do
      content_type
    else
      "application/octet-stream"
    end
  end

  defp verified_content_type(_content_type), do: "application/octet-stream"

  defp content_disposition(path, content_type) do
    filename =
      path
      |> String.trim_leading("./")
      |> Path.basename()

    fallback =
      filename
      |> String.to_charlist()
      |> Enum.map_join(fn
        character
        when character in 0x20..0x7E and character not in [?", ?\\] ->
          <<character>>

        _unsafe ->
          "_"
      end)
      |> case do
        "" -> "attachment"
        safe -> safe
      end

    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    disposition = if inline_media_type?(content_type), do: "inline", else: "attachment"
    ~s(#{disposition}; filename="#{fallback}"; filename*=UTF-8''#{encoded})
  end

  defp inline_media_type?(content_type),
    do: String.downcase(content_type) in @inline_media_types

  defp not_found(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(404, Jason.encode!(%{errors: %{detail: "Not Found"}}))
  end

  defp service_unavailable(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(503, Jason.encode!(%{errors: %{detail: "Service Unavailable"}}))
  end

  defp log_storage_error(note_id, path, reason) do
    GSMLG.Telemetry.error("Admin GaoNote attachment content stream failed",
      metadata: %{
        module: __MODULE__,
        note_id: note_id,
        path: path,
        reason: storage_error_kind(reason)
      }
    )
  end

  defp abort_stream!(note_id, path, reason) do
    log_storage_error(note_id, path, reason)
    exit({:shutdown, :gao_note_attachment_storage_read_failed})
  end

  defp storage_error_kind(:unexpected_chunk_size), do: :unexpected_chunk_size
  defp storage_error_kind({:exception, _reason}), do: :exception
  defp storage_error_kind({kind, _reason}) when kind in [:exit, :throw], do: kind
  defp storage_error_kind(_reason), do: :storage_error
end
