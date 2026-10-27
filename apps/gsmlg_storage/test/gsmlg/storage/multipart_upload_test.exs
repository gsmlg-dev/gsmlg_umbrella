defmodule GSMLG.Storage.MultipartUploadTest do
  use ExUnit.Case, async: false

  alias GSMLG.Repo
  alias GSMLG.Storage
  alias GSMLG.Storage.{S3Client, StorageFile, TestCatalogClient}

  @moduletag :tmp_dir
  @part_size 5_242_880

  defmodule S3Server do
    import Plug.Conn

    def init(options), do: options

    def call(conn, options) do
      conn = fetch_query_params(conn)
      {:ok, body, conn} = read_all(conn, [])

      send(options[:test_pid], {
        :s3_request,
        conn.method,
        conn.query_params,
        body,
        get_req_header(conn, "authorization")
      })

      respond(conn, body, options)
    end

    defp respond(%{method: "POST", query_params: %{"uploads" => _}} = conn, _, options) do
      upload_id =
        case options[:initiate] do
          :missing -> ""
          :empty -> "<UploadId></UploadId>"
          _ -> "<UploadId>test-upload-id</UploadId>"
        end

      xml(conn, 200, """
      <InitiateMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Bucket>multipart-test</Bucket><Key>attachment.pdf</Key>#{upload_id}
      </InitiateMultipartUploadResult>
      """)
    end

    defp respond(%{method: "PUT", query_params: %{"partNumber" => _}} = conn, body, options) do
      case options[:etag] do
        :missing -> send_resp(conn, 200, "")
        :empty -> conn |> put_resp_header("etag", "") |> send_resp(200, "")
        _ -> conn |> put_resp_header("etag", etag(body)) |> send_resp(200, "")
      end
    end

    defp respond(%{method: "POST", query_params: %{"uploadId" => _}} = conn, body, options) do
      cond do
        AWS.XML.decode!(body) != options[:complete] or options[:fail_complete] == true ->
          xml(conn, 400, "<Error><Code>MalformedXML</Code></Error>")

        options[:fail_complete] == :embedded ->
          xml(conn, 200, "<Error><Code>InternalError</Code></Error>")

        true ->
          xml(conn, 200, """
          <CompleteMultipartUploadResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
            <Location>http://localhost/multipart-test/attachment.pdf</Location>
            <Bucket>multipart-test</Bucket><Key>attachment.pdf</Key><ETag>"complete"</ETag>
          </CompleteMultipartUploadResult>
          """)
      end
    end

    defp respond(%{method: "DELETE", query_params: %{"uploadId" => _}} = conn, _, _) do
      send_resp(conn, 204, "")
    end

    defp read_all(conn, chunks) do
      case read_body(conn, length: 1_048_576) do
        {:more, chunk, conn} -> read_all(conn, [chunk | chunks])
        {:ok, chunk, conn} -> {:ok, IO.iodata_to_binary(Enum.reverse([chunk | chunks])), conn}
      end
    end

    defp xml(conn, status, body),
      do: conn |> put_resp_content_type("application/xml") |> send_resp(status, body)

    defp etag(body), do: "\"" <> Base.encode16(:crypto.hash(:md5, body), case: :lower) <> "\""
  end

  setup context do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    TestCatalogClient.setup!()
    {:ok, _} = Application.ensure_all_started(:gaoxy_http)
    {:ok, _} = Application.ensure_all_started(:http_fetch)

    content = "%PDF-1.7\n" <> :binary.copy("attachment-content\n", 300_000)
    <<first::binary-size(@part_size), second::binary>> = content
    path = Path.join(context.tmp_dir, "attachment.pdf")
    File.write!(path, content)

    complete = %{
      "CompleteMultipartUpload" => %{
        "Part" => [
          %{"PartNumber" => "1", "ETag" => etag(first)},
          %{"PartNumber" => "2", "ETag" => etag(second)}
        ]
      }
    }

    options =
      Keyword.merge(
        [test_pid: self(), complete: complete],
        context |> Map.take([:initiate, :etag, :fail_complete]) |> Map.to_list()
      )

    server =
      start_supervised!(
        {Gaoxy.HTTP, plug: {S3Server, options}, port: 0, limits: %{max_bytes: 8_388_608}}
      )

    {:ok, {_, port}} = Gaoxy.info(server, :http).local
    keys = [:s3_bucket, :s3_endpoint, :upload_reservation_dir]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    Application.put_env(:gsmlg_storage, :s3_bucket, "multipart-test")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :upload_reservation_dir, context.tmp_dir)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    {:ok, backend} = S3Client.capture_backend()

    %{
      content: content,
      first: first,
      second: second,
      path: path,
      backend: backend,
      complete: complete
    }
  end

  test "finalizes an attachment larger than 5 MiB using standard multipart S3 responses",
       context do
    checksum = sha256(context.content)

    attrs = %{
      filename: "attachment.pdf",
      content_type: "application/pdf",
      size: byte_size(context.content),
      checksum: checksum,
      expires_at: DateTime.add(DateTime.utc_now(), 300, :second)
    }

    assert {:ok, %StorageFile{status: "processing"} = reservation} =
             Storage.prepare_upload("gao_note", "attachment", attrs)

    assert :ok = Storage.write_upload(reservation.id, context.first)
    assert :ok = Storage.write_upload(reservation.id, context.second)

    assert {:ok, %StorageFile{status: "active", checksum: ^checksum} = active} =
             Storage.finalize_upload(reservation.id, s3_client: S3Client)

    assert %StorageFile{status: "active"} = Storage.get(active.id)
    assert Repo.get(StorageFile, active.id) == nil
    refute File.exists?(Path.join(context.tmp_dir, reservation.id))

    assert_receive {:s3_request, "POST", %{"uploads" => _}, _, ["AWS4-HMAC-SHA256 " <> _]}

    assert_receive {:s3_request, "PUT", %{"partNumber" => "1", "uploadId" => "test-upload-id"},
                    first, ["AWS4-HMAC-SHA256 " <> _]}

    assert_receive {:s3_request, "PUT", %{"partNumber" => "2", "uploadId" => "test-upload-id"},
                    second, ["AWS4-HMAC-SHA256 " <> _]}

    assert byte_size(first) == @part_size
    assert byte_size(first <> second) == attrs.size
    assert first <> second == context.content
    assert sha256(first <> second) == checksum

    assert_receive {:s3_request, "POST", %{"uploadId" => "test-upload-id"}, complete_body,
                    ["AWS4-HMAC-SHA256 " <> _]}

    assert AWS.XML.decode!(complete_body) == context.complete
    refute_received {:s3_request, "DELETE", _, _, _}
  end

  for invalid <- [:missing, :empty] do
    @tag initiate: invalid
    test "returns an error for a #{invalid} initiation UploadId", context do
      assert {:error, _} =
               S3Client.put_file(
                 context.backend,
                 "attachment.pdf",
                 context.path,
                 "application/pdf"
               )

      assert_receive {:s3_request, "POST", %{"uploads" => _}, _, _}
      refute_received {:s3_request, "PUT", _, _, _}
      refute_received {:s3_request, "DELETE", _, _, _}
    end

    @tag etag: invalid
    test "aborts an initiated upload with a #{invalid} part ETag", context do
      assert {:error, _} =
               S3Client.put_file(
                 context.backend,
                 "attachment.pdf",
                 context.path,
                 "application/pdf"
               )

      assert_receive {:s3_request, "PUT", %{"partNumber" => "1"}, _, _}
      assert_receive {:s3_request, "DELETE", %{"uploadId" => "test-upload-id"}, _, _}
      refute_received {:s3_request, "PUT", %{"partNumber" => "2"}, _, _}
      refute_received {:s3_request, "POST", %{"uploadId" => _}, _, _}
    end
  end

  @tag fail_complete: true
  test "aborts an upload when completing its parts fails", context do
    assert {:error, _} =
             S3Client.put_file(context.backend, "attachment.pdf", context.path, "application/pdf")

    assert_receive {:s3_request, "POST", %{"uploadId" => "test-upload-id"}, _, _}
    assert_receive {:s3_request, "DELETE", %{"uploadId" => "test-upload-id"}, _, _}
  end

  @tag fail_complete: :embedded
  test "aborts an upload when completion returns an error inside HTTP 200", context do
    assert {:error, _} =
             S3Client.put_file(context.backend, "attachment.pdf", context.path, "application/pdf")

    assert_receive {:s3_request, "POST", %{"uploadId" => "test-upload-id"}, _, _}
    assert_receive {:s3_request, "DELETE", %{"uploadId" => "test-upload-id"}, _, _}
  end

  defp etag(body), do: "\"" <> Base.encode16(:crypto.hash(:md5, body), case: :lower) <> "\""
  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
