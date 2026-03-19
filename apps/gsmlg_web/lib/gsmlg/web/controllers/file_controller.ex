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
      serve_file(conn, file.s3_key, file.content_type, file.checksum)
    else
      :error -> conn |> put_status(:not_found) |> text("Not Found")
    end
  end

  def variant(conn, %{"id" => id, "variant" => variant_name}) do
    with {:ok, file} <- fetch_active_file(id),
         %{"s3_key" => s3_key, "content_type" => ct} <-
           get_in(file.variants || %{}, [variant_name]) do
      serve_file(conn, s3_key, ct, file.checksum)
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

  defp serve_file(conn, s3_key, content_type, checksum) do
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
          conn
          |> put_resp_header("content-type", content_type)
          |> put_resp_header("content-length", to_string(byte_size(data)))
          |> put_resp_header("content-disposition", "inline")
          |> put_resp_header("cache-control", @cache_control)
          |> then(fn c -> if etag, do: put_resp_header(c, "etag", etag), else: c end)
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
