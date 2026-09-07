defmodule GSMLG.AdminWeb.Plugs.BrowserArtifactUploadIngressTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Conn
  import Plug.Test

  alias GSMLG.AdminWeb.Plugs.BrowserArtifactUploadIngress

  defmodule Service do
    def begin_upload(id, token, headers) do
      send(self(), {:begin_upload, id, token, headers})

      case Process.get(:upload_mode) do
        :reject_begin -> {:error, :invalid_upload_token}
        _mode -> {:ok, %{id: id}}
      end
    end

    def write_upload_chunk(handle, chunk) do
      send(self(), {:write_upload_chunk, handle, chunk})
      if Process.get(:upload_mode) == :reject_write, do: {:error, :upload_write_failed}, else: :ok
    end

    def finish_upload(handle) do
      send(self(), {:finish_upload, handle})

      if Process.get(:upload_mode) == :reject_finish,
        do: {:error, :integrity_failed},
        else: {:ok, %{}}
    end

    def abort_upload(handle) do
      send(self(), {:abort_upload, handle})
      :ok
    end
  end

  defmodule DisconnectingAdapter do
    def read_req_body(_state, _opts), do: exit(:client_disconnected)
  end

  setup do
    Process.delete(:upload_mode)
    :ok
  end

  test "streams an exact capability-bound PUT and returns no token-bearing representation" do
    id = Ecto.UUID.generate()
    body = "verified artifact body"
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    conn =
      :put
      |> conn("/browser-artifact-uploads/#{id}", body)
      |> put_req_header("content-type", "text/plain")
      |> put_req_header("content-length", Integer.to_string(byte_size(body)))
      |> put_req_header("x-content-sha256", sha256)
      |> put_req_header("x-browser-upload-token", token)
      |> BrowserArtifactUploadIngress.call(service: Service, chunk_size: 4)

    assert conn.halted
    assert conn.status == 204
    assert conn.resp_body == ""
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    refute inspect(conn.resp_headers) =~ token

    assert_received {:begin_upload, ^id, ^token,
                     %{
                       "content-type" => "text/plain",
                       "content-length" => expected_length,
                       "x-content-sha256" => ^sha256,
                       "x-browser-upload-token" => ^token
                     }}

    assert expected_length == Integer.to_string(byte_size(body))
    assert_received {:write_upload_chunk, %{id: ^id}, _chunk}
    assert_received {:finish_upload, %{id: ^id}}
    refute_received {:abort_upload, _handle}
  end

  test "rejects missing, malformed, query-carried, and duplicate capabilities before service" do
    id = Ecto.UUID.generate()

    for conn <- [
          conn(:put, "/browser-artifact-uploads/#{id}", "body"),
          upload_conn(id, "short", "body"),
          upload_conn(id, valid_token(), "body") |> Map.put(:query_string, "token=secret"),
          upload_conn(id, valid_token(), "body")
          |> then(fn conn ->
            %{conn | req_headers: [{"x-browser-upload-token", valid_token()} | conn.req_headers]}
          end)
        ] do
      conn = BrowserArtifactUploadIngress.call(conn, service: Service)
      assert conn.halted
      assert conn.status in [400, 401]
    end

    refute_received {:begin_upload, _, _, _}
  end

  test "normalizes begin rejection and aborts a claimed upload after streaming failure" do
    id = Ecto.UUID.generate()

    Process.put(:upload_mode, :reject_begin)

    rejected =
      upload_conn(id, valid_token(), "body")
      |> BrowserArtifactUploadIngress.call(service: Service)

    assert rejected.status == 401
    assert rejected.resp_body == ""

    Process.put(:upload_mode, :reject_write)

    failed =
      upload_conn(id, valid_token(), "body")
      |> BrowserArtifactUploadIngress.call(service: Service)

    assert failed.status == 503
    assert_received {:abort_upload, %{id: ^id}}
    refute inspect(failed.resp_body) =~ "upload_write_failed"
  end

  test "aborts a claimed upload when final integrity verification fails" do
    id = Ecto.UUID.generate()
    Process.put(:upload_mode, :reject_finish)

    failed =
      upload_conn(id, valid_token(), "body")
      |> BrowserArtifactUploadIngress.call(service: Service)

    assert failed.status == 422
    assert failed.resp_body == ""
    assert_received {:finish_upload, %{id: ^id}}
    assert_received {:abort_upload, %{id: ^id}}
  end

  test "aborts a claimed upload when the client disconnects during body streaming" do
    id = Ecto.UUID.generate()

    conn =
      id
      |> upload_conn(valid_token(), "body")
      |> Map.put(:adapter, {DisconnectingAdapter, nil})

    assert catch_exit(BrowserArtifactUploadIngress.call(conn, service: Service)) ==
             :client_disconnected

    assert_received {:begin_upload, ^id, _, _}
    assert_received {:abort_upload, %{id: ^id}}
  end

  test "never logs the upload capability or request URL" do
    id = Ecto.UUID.generate()
    token = valid_token()
    path = "/browser-artifact-uploads/#{id}"

    log =
      capture_log(fn ->
        assert %{status: 204} =
                 upload_conn(id, token, "body")
                 |> BrowserArtifactUploadIngress.call(service: Service)
      end)

    refute log =~ token
    refute log =~ path
  end

  test "non-upload requests pass through untouched" do
    conn = conn(:get, "/api/browser/nodes") |> BrowserArtifactUploadIngress.call(service: Service)
    refute conn.halted
    assert conn.status == nil
  end

  defp upload_conn(id, token, body) do
    sha256 = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

    :put
    |> conn("/browser-artifact-uploads/#{id}", body)
    |> put_req_header("content-type", "text/plain")
    |> put_req_header("content-length", Integer.to_string(byte_size(body)))
    |> put_req_header("x-content-sha256", sha256)
    |> put_req_header("x-browser-upload-token", token)
  end

  defp valid_token, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
end
