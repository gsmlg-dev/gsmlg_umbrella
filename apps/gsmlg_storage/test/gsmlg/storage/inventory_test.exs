defmodule GSMLG.Storage.InventoryTest do
  use ExUnit.Case, async: true

  alias GSMLG.Storage.{Inventory, S3Client}

  defmodule HTTPClient do
    @behaviour AWS.HTTPClient

    def request(method, url, body, headers, options) do
      options[:handler].(method, url, body, headers)
    end
  end

  defmodule S3Server do
    import Plug.Conn

    def init(options), do: options

    def call(conn, options) do
      conn = fetch_query_params(conn)

      send(
        options[:test_pid],
        {:s3_request, conn.query_params, get_req_header(conn, "authorization")}
      )

      body = Map.fetch!(options[:pages], conn.query_params["continuation-token"])
      conn |> put_resp_content_type("application/xml") |> send_resp(200, body)
    end
  end

  test "scans through the production HTTP transport and signs every request" do
    {:ok, _} = Application.ensure_all_started(:bandit)
    {:ok, _} = Application.ensure_all_started(:finch)

    if is_nil(Process.whereis(GSMLG.AWS.Finch)) do
      start_supervised!({Finch, name: GSMLG.AWS.Finch})
    end

    server =
      start_supervised!(
        {Bandit,
         plug:
           {S3Server,
            test_pid: self(),
            pages: %{
              nil => page([{"outside &+.txt", 4}], true, "next&token"),
              "next&token" => page([{"folder/file.txt", 8}], false)
            }},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, backend} =
      Inventory.backend(
        s3_bucket: "inventory-test",
        s3_endpoint: "http://127.0.0.1:#{port}",
        s3_access_key_id: "test-access",
        s3_secret_access_key: "test-secret"
      )

    assert {:ok,
            %{objects: [%{key: "outside &+.txt", size: 4}, %{key: "folder/file.txt", size: 8}]}} =
             Inventory.load(backend)

    assert_receive {:s3_request, %{"encoding-type" => "url"}, ["AWS4-HMAC-SHA256 " <> _]}

    assert_receive {:s3_request, %{"continuation-token" => "next&token"},
                    ["AWS4-HMAC-SHA256 " <> _]}
  end

  test "captures backend identity without storing credentials in inventory snapshots" do
    backend = backend(fn _, _, _, _ -> response(page([], false)) end)

    assert {:ok, %{backend_id: id, bucket: "inventory-test", objects: []} = snapshot} =
             Inventory.load(backend)

    assert id == Inventory.backend_id(backend)
    refute Map.has_key?(snapshot, :client)
    refute inspect(snapshot) =~ "test-secret"

    config = [s3_bucket: "other", s3_access_key_id: "", s3_secret_access_key: ""]
    assert {:error, :missing_s3_access_key_id} = Inventory.backend(config)
    assert is_binary(S3Client.current_backend_id(config))
    refute S3Client.current_backend_id(config) == id
  end

  test "scans every page with one client and preserves exact decoded keys" do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)
    special = "  dir/中文 +%&#?\r.txt  "

    backend =
      backend(fn :get, url, _, headers ->
        query = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
        assert query["encoding-type"] == "url"
        assert Enum.any?(headers, fn {name, _} -> String.downcase(name) == "authorization" end)
        Agent.update(calls, &[query | &1])

        case query["continuation-token"] do
          nil -> response(page([{special, 123}, {"empty/", 0}], true, "next+token&"))
          "next+token&" -> response(page([{"root.txt", 7}], false))
        end
      end)

    assert {:ok, %{objects: [first, marker, last]}} = Inventory.load(backend)
    assert %{key: ^special, size: 123, folder?: false} = first
    assert %{key: "empty/", size: 0, folder?: true} = marker
    assert %{key: "root.txt", size: 7} = last
    assert [_, _] = Agent.get(calls, & &1)
    assert {:ok, ^special} = special |> Inventory.encode_key() |> Inventory.decode_key()
    assert {:error, :invalid_object_key} = Inventory.decode_key("!")
  end

  test "page failure never returns the successful first page as a snapshot" do
    backend =
      backend(fn _, url, _, _ ->
        if URI.decode_query(URI.parse(url).query)["continuation-token"] do
          {:error, :offline}
        else
          response(page([{"first.txt", 4}], true, "next"))
        end
      end)

    assert {:error, :offline} = Inventory.load(backend)
  end

  test "rejects malformed pages, invalid sizes, missing tokens and repeated tokens" do
    invalid_pages = [
      "<ListBucketResult>",
      "<Other />",
      page([{"bad.txt", "-1"}], false),
      page([], true),
      String.replace(page([], false), "<IsTruncated>false</IsTruncated>", ""),
      String.replace(page([{"good", 1}], false), "<Key>good</Key>", "<Key>bad%xx</Key>"),
      String.replace(page([{"good", 1}], false), "<Key>good</Key>", "<Key>%FF</Key>")
    ]

    for xml <- invalid_pages do
      assert {:error, :invalid_s3_list_response} =
               Inventory.load(backend(fn _, _, _, _ -> response(xml) end))
    end

    assert {:error, :repeated_s3_continuation_token} =
             Inventory.load(backend(fn _, _, _, _ -> response(page([], true, "same")) end))
  end

  test "malformed later page fails the whole snapshot" do
    backend =
      backend(fn _, url, _, _ ->
        if URI.decode_query(URI.parse(url).query)["continuation-token"] do
          response(page([{"bad.txt", "unknown"}], false))
        else
          response(page([{"first.txt", 4}], true, "next"))
        end
      end)

    assert {:error, :invalid_s3_list_response} = Inventory.load(backend)
  end

  test "projects actual prefixes, empty folders, integer totals, search and pagination" do
    objects = [
      object("root.txt", 3),
      object("folder/a.txt", 5),
      object("folder/b.txt", 7),
      object("folder/nested/c.txt", 11),
      object("empty/", 0),
      object("other.txt", 13)
    ]

    assert %{
             total: 2,
             folders: [%{prefix: "empty/", count: 0}, %{prefix: "folder/", count: 3}],
             stats: %{total_files: 5, total_size: 39, total_folders: 3}
           } = Inventory.project(objects)

    assert %{
             objects: [%{key: "folder/b.txt"}],
             total: 2,
             page: 2,
             total_pages: 2,
             folders: [%{prefix: "folder/nested/"}],
             stats: %{total_files: 3, total_size: 23}
           } = Inventory.project(objects, prefix: "folder/", page: 2, page_size: 1)

    assert %{objects: [%{key: "folder/nested/c.txt"}], total: 1} =
             Inventory.project(objects, prefix: "folder/", search: "C.TXT")

    assert %{objects: [], folders: [], stats: %{total_files: 0, total_size: 0}} =
             Inventory.project(objects, prefix: "empty/")
  end

  test "reads HEAD metadata and exact key from S3 response headers" do
    key = "a folder/+%?.txt"

    backend =
      backend(fn :head, url, _, _ ->
        assert URI.decode(URI.parse(url).path) == "/inventory-test/" <> key

        {:ok,
         %{
           status_code: 200,
           body: "",
           headers: [
             {"Content-Length", "16"},
             {"Content-Type", "text/plain"},
             {"ETag", "\"etag\""},
             {"Last-Modified", "Wed, 14 Oct 2026 01:00:00 GMT"},
             {"x-amz-meta-original-name", "note.txt"}
           ]
         }}
      end)

    assert {:ok,
            %{
              key: ^key,
              size: 16,
              content_type: "text/plain",
              metadata: %{"original-name" => "note.txt"},
              last_modified: "Wed, 14 Oct 2026 01:00:00 GMT"
            }} = S3Client.head_object(backend, key)
  end

  test "HEAD failures and missing sizes are explicit errors" do
    assert {:error, :offline} =
             S3Client.head_object(backend(fn _, _, _, _ -> {:error, :offline} end), "key")

    assert {:error, :invalid_s3_object_size} =
             S3Client.head_object(backend(fn _, _, _, _ -> response("") end), "key")
  end

  defp backend(handler) do
    {:ok, backend} =
      Inventory.backend(
        s3_bucket: "inventory-test",
        s3_endpoint: "http://localhost:9000",
        s3_access_key_id: "test-access",
        s3_secret_access_key: "test-secret"
      )

    %{
      backend
      | client: AWS.Client.put_http_client(backend.client, {HTTPClient, [handler: handler]})
    }
  end

  defp object(key, size),
    do: %{key: key, size: size, folder?: size == 0 and String.ends_with?(key, "/")}

  defp response(body), do: {:ok, %{status_code: 200, headers: [], body: body}}

  defp page(objects, truncated, token \\ nil) do
    contents =
      Enum.map_join(objects, "", fn {key, size} ->
        "<Contents><Key>#{URI.encode(key, &URI.char_unreserved?/1)}</Key>" <>
          "<Size>#{size}</Size><LastModified>2026-10-14T01:00:00Z</LastModified>" <>
          "<ETag>&quot;etag&quot;</ETag></Contents>"
      end)

    continuation =
      if token, do: "<NextContinuationToken>#{escape(token)}</NextContinuationToken>", else: ""

    "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" <>
      "<EncodingType>url</EncodingType><IsTruncated>#{truncated}</IsTruncated>" <>
      contents <> continuation <> "</ListBucketResult>"
  end

  defp escape(value), do: String.replace(value, "&", "&amp;")
end
