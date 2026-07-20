defmodule GSMLG.Web.GaoNoteMCPControllerTest do
  use GSMLG.Web.ConnCase, async: false

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/*path" do
      ranges = Plug.Conn.get_req_header(conn, "range")
      object = Application.get_env(:gsmlg_storage, :gao_note_mcp_public_object, "")

      if pid = Application.get_env(:gsmlg_storage, :gao_note_mcp_public_pid) do
        send(pid, {:s3_get, conn.request_path, ranges})
      end

      case ranges do
        ["bytes=" <> range] ->
          [first, last] =
            range
            |> String.split("-", parts: 2)
            |> Enum.map(&String.to_integer/1)

          send_resp(conn, 206, binary_part(object, first, last - first + 1))

        _ranges ->
          send_resp(conn, 200, object)
      end
    end

    match _, do: send_resp(conn, 200, "")
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Note}
  alias GSMLG.Accounts.User
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @storage_keys [
    :gao_note_mcp_public_object,
    :gao_note_mcp_public_pid,
    :s3_access_key_id,
    :s3_bucket,
    :s3_endpoint,
    :s3_secret_access_key
  ]

  setup do
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    original = Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: 0, startup_log: false)
    {:ok, {_address, port}} = ThousandIsland.listener_info(s3_stub)

    Application.put_env(:gsmlg_storage, :gao_note_mcp_public_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_mcp_public_pid, self())
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-access-key")
    Application.put_env(:gsmlg_storage, :s3_bucket, "gsmlg-storage")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret-key")

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      if Process.alive?(s3_stub), do: GenServer.stop(s3_stub)
    end)

    :ok
  end

  test "public MCP initialize is handled by Backplane Streamable HTTP", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => "2025-06-18",
          "capabilities" => %{},
          "clientInfo" => %{"name" => "gao-note-test", "version" => "0.1.0"}
        }
      })

    assert [_session_id] = get_resp_header(conn, "mcp-session-id")

    assert %{
             "result" => %{
               "serverInfo" => %{"name" => "gsmlg-gao-note-readonly"},
               "capabilities" => %{"tools" => %{}, "resources" => %{}}
             }
           } = json_response(conn, 200)
  end

  test "public MCP tools/list exposes readonly tools only", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/list",
        "params" => %{}
      })

    names = conn |> json_response(200) |> get_in(["result", "tools"]) |> Enum.map(& &1["name"])

    assert Enum.sort(names) == ~w(
             gao_note.get
             gao_note.get_attachment_with_content
             gao_note.list_label_settings
             gao_note.search
           )

    refute "gao_note.create" in names
    refute "gao_note.create_note" in names
    refute "gao_note.update" in names
    refute "gao_note.update_note" in names
    refute "gao_note.list_attachments" in names
    refute "gao_note.put_attachment" in names
    refute "gao_note.delete_attachment" in names
    refute Enum.any?(names, &String.starts_with?(&1, "gao_note.attachments."))
    refute Enum.any?(names, &String.contains?(&1, ["reference", "asset"]))
    refute "gao_note.assets.upload_base64" in names
  end

  test "public MCP search returns notes without publishing metadata", %{conn: conn} do
    created_note = note_fixture(%{title: "MCP Visible"})

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/mcp/gao_note", %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{
          "name" => "gao_note.search",
          "arguments" => %{"query" => "MCP"}
        }
      })

    assert %{"result" => %{"structuredContent" => %{"notes" => [note]}}} =
             json_response(conn, 200)

    assert note["id"] == created_note.id
    assert note["title"] == "MCP Visible"
    assert note["content"] == "Content"
    assert note["attachments"] == []
    assert note["created_at"]
    refute Map.has_key?(note, "body")
    refute Map.has_key?(note, "body_format")
    refute Map.has_key?(note, "created_by_id")
    refute Map.has_key?(note, "updated_by_id")
    refute Map.has_key?(note, "metadata")
    refute Map.has_key?(note, "slug")
    refute Map.has_key?(note, "summary")
    refute Map.has_key?(note, "status")
    refute Map.has_key?(note, "visibility")
  end

  test "public MCP tools/call returns binary attachment Base64 and not-found errors", %{
    conn: conn
  } do
    bytes = <<0, 1, 2, 3, 255>>
    note = note_fixture(%{title: "Public binary attachment"})

    attachment =
      attachment_fixture(note, %{
        id: "public-binary-#{System.unique_integer([:positive])}",
        path: "files/blob.bin",
        mime: "application/octet-stream",
        description: "Binary bytes",
        object: bytes
      })

    content_conn =
      call_mcp_tool(conn, "gao_note.get_attachment_with_content", %{
        "note_id" => note.id,
        "attachment_id" => attachment.id
      })

    assert %{"result" => %{"structuredContent" => %{"attachment" => presented}}} =
             json_response(content_conn, 200)

    assert presented == %{
             "id" => attachment.id,
             "path" => "./files/blob.bin",
             "mime" => "application/octet-stream",
             "description" => "Binary bytes",
             "content_url" =>
               "/api/gao_notes/#{note.id}/attachments/files/blob.bin",
             "content_base64" => Base.encode64(bytes)
           }

    assert_receive {:s3_get, _path, ["bytes=0-4"]}

    missing_conn =
      conn
      |> recycle()
      |> call_mcp_tool("gao_note.get_attachment_with_content", %{
        "note_id" => note.id,
        "attachment_id" => "missing-attachment"
      })

    assert %{
             "result" => %{
               "isError" => true,
               "content" => [%{"text" => message}]
             }
           } = json_response(missing_conn, 200)

    assert message =~ "not_found"
    refute_received {:s3_get, _path, _ranges}
  end

  defp call_mcp_tool(conn, name, arguments) do
    conn
    |> put_req_header("accept", "application/json")
    |> post(~p"/mcp/gao_note", %{
      "jsonrpc" => "2.0",
      "id" => System.unique_integer([:positive]),
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    })
  end

  defp actor do
    unless Repo.get(User, "public-test") do
      Repo.insert!(%User{
        id: "public-test",
        username: "public-test",
        email: "public-test@example.test",
        password: "test"
      })
    end

    %{id: "public-test"}
  end

  defp note_fixture(attrs) do
    attrs =
      Map.merge(
        %{
          title: "Draft #{System.unique_integer([:positive])}",
          content: "Content"
        },
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, actor())
    note
  end

  defp attachment_fixture(note, attrs) do
    object = Map.fetch!(attrs, :object)
    path = Map.fetch!(attrs, :path)
    mime = Map.fetch!(attrs, :mime)
    Application.put_env(:gsmlg_storage, :gao_note_mcp_public_object, object)

    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: note.id,
        type: "gao_note_attachment",
        filename: Path.basename(path),
        s3_key: "gao_note/#{Ecto.UUID.generate()}",
        content_type: mime,
        size: byte_size(object),
        checksum: Ecto.UUID.generate(),
        metadata: %{},
        variants: %{},
        status: "active",
        uploaded_by: "fixture"
      })
      |> Repo.insert!()

    attachment =
      %Attachment{}
      |> Attachment.changeset(%{
        id: Map.fetch!(attrs, :id),
        note_id: note.id,
        storage_file_id: file.id,
        path: path,
        mime: mime,
        description: Map.get(attrs, :description, "")
      })
      |> Repo.insert!()

    Repo.preload(attachment, :storage_file)
  end

end
