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
    case Storage.get_active(id) do
      nil ->
        conn |> put_status(:not_found) |> text("Not Found")

      file ->
        serve_file(conn, file, file.s3_key, file.content_type, file.size, file.checksum)
    end
  end

  def variant(conn, %{"id" => id, "variant" => variant_name}) do
    case Storage.get_active(id) do
      nil ->
        conn |> put_status(:not_found) |> text("Not Found")

      file ->
        case get_in(file.variants || %{}, [variant_name]) do
          %{"s3_key" => s3_key, "content_type" => ct, "size" => size} ->
            serve_file(conn, file, s3_key, ct, size, file.checksum)

          _ ->
            conn |> put_status(:not_found) |> text("Variant Not Found")
        end
    end
  end

  defp serve_file(conn, _file, s3_key, content_type, size, checksum) do
    etag = ~s("#{checksum}")

    if match_etag?(conn, etag) do
      conn
      |> put_resp_header("etag", etag)
      |> put_resp_header("cache-control", @cache_control)
      |> send_resp(304, "")
    else
      bucket = Application.get_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")

      case S3Client.get_object(bucket, s3_key) do
        {:ok, data} ->
          conn
          |> put_resp_header("content-type", content_type)
          |> put_resp_header("content-length", to_string(size))
          |> put_resp_header("content-disposition", "inline")
          |> put_resp_header("cache-control", @cache_control)
          |> put_resp_header("etag", etag)
          |> send_resp(200, data)

        {:error, _reason} ->
          conn |> put_status(:not_found) |> text("Not Found")
      end
    end
  end

  defp match_etag?(conn, etag) do
    case get_req_header(conn, "if-none-match") do
      [^etag] -> true
      _ -> false
    end
  end
end
