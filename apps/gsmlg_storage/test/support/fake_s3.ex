defmodule GSMLG.Storage.FakeS3 do
  @moduledoc false
  # Local HTTP S3 stand-in for S3Client tests. Each request is passed to
  # `handler.(method, url, body, headers)`, which returns
  # `{:ok, %{status_code: _, headers: _, body: _}}` or `{:error, reason}`.
  # `chunked: true` sends the status without a Content-Length.
  # Errors abort the connection so the client sees a transport failure.

  import Plug.Conn

  alias GSMLG.Storage.S3Client

  @doc "Starts a fake endpoint under the test supervisor and captures a backend for it."
  def backend!(bucket, handler) do
    {:ok, _} = Application.ensure_all_started(:gaoxy_http)
    {:ok, _} = Application.ensure_all_started(:http_fetch)

    server =
      ExUnit.Callbacks.start_supervised!(
        Supervisor.child_spec({Gaoxy.HTTP, plug: {__MODULE__, handler}, port: 0}, id: make_ref())
      )

    {:ok, {_, port}} = Gaoxy.info(server, :http).local

    {:ok, backend} =
      S3Client.capture_backend(
        s3_bucket: bucket,
        s3_endpoint: "http://127.0.0.1:#{port}",
        s3_access_key_id: "test-access",
        s3_secret_access_key: "test-secret"
      )

    backend
  end

  def init(handler), do: handler

  def call(conn, handler) do
    {:ok, body, conn} = read_all(conn, [])
    query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
    url = "http://#{conn.host}:#{conn.port}#{conn.request_path}#{query}"
    method = conn.method |> String.downcase() |> String.to_existing_atom()

    case handler.(method, url, body, conn.req_headers) do
      {:ok, %{status_code: status, headers: headers, body: body} = response} ->
        conn =
          Enum.reduce(headers, conn, fn {name, value}, conn ->
            put_resp_header(conn, String.downcase(name), value)
          end)

        if response[:chunked],
          do: send_chunked(conn, status),
          else: send_resp(conn, status, body)

      {:error, reason} ->
        {:ok, conn} = Gaoxy.HTTP.abort(conn, reason)
        halt(conn)
    end
  end

  defp read_all(conn, chunks) do
    case read_body(conn, length: 1_048_576) do
      {:more, chunk, conn} -> read_all(conn, [chunk | chunks])
      {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
    end
  end
end
