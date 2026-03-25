defmodule GSMLG.Web.FileController do
  @moduledoc """
  Serves stored files publicly via streaming from S3.
  No authentication required — all active files are publicly accessible.
  """

  use GSMLG.Web, :controller

  alias GSMLG.Storage
  alias GSMLG.Storage.S3Client

  @cache_control "public, max-age=31536000, immutable"

  def show(conn, %{"id" => id}) do
    with {:ok, file} <- fetch_active_file(id) do
      serve_file(conn, file.s3_key, file.content_type, file.size, file.checksum)
    else
      :error -> conn |> put_status(:not_found) |> text("Not Found")
    end
  end

  def variant(conn, %{"id" => id, "variant" => variant_name}) do
    with {:ok, file} <- fetch_active_file(id),
         %{"s3_key" => s3_key, "content_type" => ct, "size" => size} <-
           get_in(file.variants || %{}, [variant_name]) do
      serve_file(conn, s3_key, ct, size, file.checksum)
    else
      _ -> conn |> put_status(:not_found) |> text("Not Found")
    end
  end

  defp fetch_active_file(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        case Storage.get_active(id) do
          nil -> :error
          file -> {:ok, file}
        end

      :error ->
        :error
    end
  end

  defp serve_file(conn, s3_key, content_type, total_size, checksum) do
    etag = if checksum, do: ~s("#{checksum}"), else: nil

    if etag && match_etag?(conn, etag) do
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", @cache_control)
      |> send_resp(304, "")
    else
      bucket = Application.get_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")

      case S3Client.get_object(bucket, s3_key) do
        {:ok, data} ->
          serve_data(conn, data, content_type, total_size, etag)

        {:error, _reason} ->
          conn |> put_status(:not_found) |> text("Not Found")
      end
    end
  end

  defp serve_data(conn, data, content_type, _total_size, etag) do
    total = byte_size(data)

    case parse_range(conn, total) do
      nil ->
        # Full response
        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("content-length", to_string(total))
        |> put_resp_header("content-disposition", content_disposition(content_type))
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_header("accept-ranges", "bytes")
        |> then(fn c -> if etag, do: put_resp_header(c, "etag", etag), else: c end)
        |> send_resp(200, data)

      {:ok, range_start, range_end} ->
        # Partial content (206)
        length = range_end - range_start + 1
        slice = binary_part(data, range_start, length)

        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("content-length", to_string(length))
        |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{total}")
        |> put_resp_header("content-disposition", content_disposition(content_type))
        |> put_resp_header("cache-control", @cache_control)
        |> put_resp_header("accept-ranges", "bytes")
        |> then(fn c -> if etag, do: put_resp_header(c, "etag", etag), else: c end)
        |> send_resp(206, slice)

      :invalid ->
        conn
        |> put_resp_header("content-range", "bytes */#{total}")
        |> send_resp(416, "Range Not Satisfiable")
    end
  end

  # Parse Range header. Returns nil (no range), {:ok, start, end}, or :invalid.
  defp parse_range(conn, total) do
    case get_req_header(conn, "range") do
      ["bytes=" <> range_spec] -> parse_byte_range(range_spec, total)
      _ -> nil
    end
  end

  defp parse_byte_range(spec, total) do
    case String.split(spec, "-", parts: 2) do
      [start_str, ""] when start_str != "" ->
        # "N-" — from byte N to end
        case Integer.parse(start_str) do
          {start, ""} when start >= 0 and start < total ->
            {:ok, start, total - 1}

          _ ->
            :invalid
        end

      ["", suffix_str] when suffix_str != "" ->
        # "-N" — last N bytes
        case Integer.parse(suffix_str) do
          {suffix, ""} when suffix > 0 ->
            start = max(0, total - suffix)
            {:ok, start, total - 1}

          _ ->
            :invalid
        end

      [start_str, end_str] ->
        with {start, ""} <- Integer.parse(start_str),
             {range_end, ""} <- Integer.parse(end_str),
             true <- start >= 0 and start <= range_end and start < total do
          {:ok, start, min(range_end, total - 1)}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  # SVG and HTML can execute scripts when served inline — force download.
  @unsafe_inline_types ~w(image/svg+xml text/html application/xhtml+xml)

  defp content_disposition(content_type) when content_type in @unsafe_inline_types,
    do: "attachment"

  defp content_disposition(_), do: "inline"

  defp match_etag?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [^etag] -> true
      _ -> false
    end
  end
end
