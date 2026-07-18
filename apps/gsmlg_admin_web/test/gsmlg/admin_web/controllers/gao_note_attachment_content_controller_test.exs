defmodule GSMLG.AdminWeb.GaoNoteAttachmentContentControllerTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  defmodule S3Stub do
    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/*path" do
      ranges = Plug.Conn.get_req_header(conn, "range")

      if pid = Application.get_env(:gsmlg_storage, :gao_note_http_admin_pid) do
        send(pid, {:s3_get, conn.request_path, ranges})
      end

      object = Application.get_env(:gsmlg_storage, :gao_note_http_admin_object, "")
      fail_ranges =
        Application.get_env(:gsmlg_storage, :gao_note_http_admin_fail_ranges, [])

      case {ranges, List.first(ranges) in fail_ranges} do
        {_ranges, true} ->
          send_resp(conn, 500, "admin upstream detail")

        {["bytes=" <> range], false} ->
          [first, last] =
            range
            |> String.split("-", parts: 2)
            |> Enum.map(&String.to_integer/1)

          body = binary_part(object, first, last - first + 1)
          send_resp(conn, 206, body)
      end
    end

    match _, do: send_resp(conn, 200, "")
  end

  alias GSMLG.GaoNote
  alias GSMLG.GaoNote.{Attachment, Label, LabelSetting, Log, Note, Presenter}
  alias GSMLG.Repo
  alias GSMLG.Storage.StorageFile

  @storage_keys [
    :gao_note_http_admin_fail_ranges,
    :gao_note_http_admin_object,
    :gao_note_http_admin_pid,
    :s3_access_key_id,
    :s3_bucket,
    :s3_endpoint,
    :s3_secret_access_key
  ]

  setup %{conn: conn} do
    Repo.delete_all(Log)
    Repo.delete_all(Attachment)
    Repo.delete_all(Label)
    Repo.delete_all(LabelSetting)
    Repo.delete_all(Note)
    Repo.delete_all(StorageFile)

    original = Map.new(@storage_keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    port = available_port()
    {:ok, s3_stub} = Bandit.start_link(plug: S3Stub, port: port, startup_log: false)

    Application.put_env(:gsmlg_storage, :gao_note_http_admin_fail_ranges, [])
    Application.put_env(:gsmlg_storage, :gao_note_http_admin_object, "")
    Application.put_env(:gsmlg_storage, :gao_note_http_admin_pid, self())
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

    {:ok, conn: put_req_header(conn, "accept", "*/*"), user: user_fixture()}
  end

  test "admin raw content requires the existing bearer auth pipeline", %{
    conn: conn,
    user: user
  } do
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin.txt", "admin")

    conn = get(conn, Presenter.attachment(attachment)["content_url"])

    assert json_response(conn, 401)["message"] =~ "no_resource"
    refute_received {:s3_get, _path, _ranges}
  end

  test "admin browser session serves note-scoped raw attachment content", %{
    conn: conn,
    user: user
  } do
    note = note_fixture(user)
    _attachment = attachment_fixture(note, "./browser.txt", "browser body")

    conn = session_authenticated_conn(conn, user)
    assert get_req_header(conn, "authorization") == []

    conn =
      get(
        conn,
        "/gao_notes/notes/#{note.id}/attachments/browser.txt"
      )

    assert response(conn, 200) == "browser body"
    assert get_resp_header(conn, "content-type") == ["text/plain"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
  end

  test "admin serves active and logically deleted note attachments", %{
    conn: conn,
    user: user
  } do
    active_note = note_fixture(user, %{title: "Active inspection"})
    active = attachment_fixture(active_note, "./active.txt", "active body")

    active_conn =
      conn
      |> authenticated_conn(user)
      |> get(Presenter.attachment(active)["content_url"])

    assert response(active_conn, 200) == "active body"
    assert get_resp_header(active_conn, "content-type") == ["text/plain"]
    assert get_resp_header(active_conn, "accept-ranges") == ["bytes"]

    deleted_note = note_fixture(user, %{title: "Recycle inspection"})
    deleted = attachment_fixture(deleted_note, "./deleted.txt", "deleted body")
    assert {:ok, _deleted_note} = GaoNote.delete_note(deleted_note, user)

    deleted_conn =
      conn
      |> recycle()
      |> authenticated_conn(user)
      |> put_req_header("range", "bytes=1-5")
      |> get(Presenter.attachment(deleted)["content_url"])

    assert response(deleted_conn, 206) == "elete"
    assert get_resp_header(deleted_conn, "content-range") == ["bytes 1-5/12"]
    assert_receive {:s3_get, _path, ["bytes=0-10"]}
    assert_receive {:s3_get, _path, ["bytes=1-5"]}
  end

  test "admin serves encoded canonical paths with attachment MIME and safe disposition", %{
    conn: conn,
    user: user
  } do
    object = "admin encoded"
    note = note_fixture(user)

    attachment =
      attachment_fixture(note, "./docs/資料 #1?%.txt", object,
        mime: "application/pdf",
        content_type: "text/plain"
      )

    url = Presenter.attachment(attachment)["content_url"]

    conn =
      conn
      |> authenticated_conn(user)
      |> get(url)

    assert response(conn, 200) == object
    assert get_resp_header(conn, "content-type") == ["application/pdf"]
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]

    assert get_resp_header(conn, "content-disposition") == [
             "attachment; filename=\"__ #1?%.txt\"; " <>
               "filename*=UTF-8''%E8%B3%87%E6%96%99%20%231%3F%25.txt"
           ]

    encoded_slash =
      String.replace(url, "/attachments/docs/", "/attachments/docs%2F")

    encoded_slash_conn =
      build_conn()
      |> put_req_header("accept", "*/*")
      |> authenticated_conn(user)
      |> get(encoded_slash)

    assert response(encoded_slash_conn, 200) == object
  end

  test "admin forces active MIME types to download and inlines only safe raster or text", %{
    conn: conn,
    user: user
  } do
    note = note_fixture(user)

    for {mime, filename, disposition} <- [
          {"text/html", "admin-active.html", "attachment"},
          {"image/svg+xml", "admin-active.svg", "attachment"},
          {"image/png", "admin-safe.png", "inline"},
          {"text/plain", "admin-safe.txt", "inline"}
        ] do
      object = "admin content for #{mime}"
      attachment = attachment_fixture(note, "./#{filename}", object, mime: mime)

      response_conn =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> get(Presenter.attachment(attachment)["content_url"])

      assert response(response_conn, 200) == object
      assert get_resp_header(response_conn, "content-type") == [mime]
      assert get_resp_header(response_conn, "x-content-type-options") == ["nosniff"]

      assert [header] = get_resp_header(response_conn, "content-disposition")
      assert String.starts_with?(header, ~s(#{disposition}; filename="#{filename}";))
    end
  end

  test "admin returns 404 for controller-reachable invalid and unknown canonical paths", %{
    user: user
  } do
    note = note_fixture(user)

    for suffix <- [
          "",
          "%2E%2E/secret.txt",
          "safe/%2E%2E/secret.txt",
          "%2Fetc/passwd",
          "unknown.txt",
          "%00.txt"
        ] do
      conn =
        build_conn()
        |> put_req_header("accept", "*/*")
        |> authenticated_conn(user)
        |> get("/api/gao_notes/#{note.id}/attachments/#{suffix}")

      assert conn.status == 404
    end

    refute_received {:s3_get, _path, _ranges}
  end

  test "admin returns 400 when Phoenix or Plug rejects malformed URI encoding", %{user: user} do
    note = note_fixture(user)

    for suffix <- ["%ZZ", "%FF.txt"] do
      conn =
        build_conn()
        |> put_req_header("accept", "*/*")
        |> authenticated_conn(user)
        |> get("/api/gao_notes/#{note.id}/attachments/#{suffix}")

      assert conn.status == 400
    end

    refute_received {:s3_get, _path, _ranges}
  end

  test "admin integrates partial and invalid range handling", %{conn: conn, user: user} do
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin-ranges.txt", "0123456789")
    url = Presenter.attachment(attachment)["content_url"]

    partial =
      conn
      |> authenticated_conn(user)
      |> put_req_header("range", "bytes=-3")
      |> get(url)

    assert response(partial, 206) == "789"
    assert get_resp_header(partial, "content-range") == ["bytes 7-9/10"]

    for range <- ["bytes=bad", "bytes=0-1,4-5", "bytes=10-"] do
      invalid =
        conn
        |> recycle()
        |> authenticated_conn(user)
        |> put_req_header("range", range)
        |> get(url)

      assert response(invalid, 416) == ""
      assert get_resp_header(invalid, "content-range") == ["bytes */10"]
    end
  end

  test "admin serves zero bytes without S3 and rejects a zero-byte range", %{
    conn: conn,
    user: user
  } do
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin-empty.txt", "")
    url = Presenter.attachment(attachment)["content_url"]

    full =
      conn
      |> authenticated_conn(user)
      |> get(url)

    assert response(full, 200) == ""
    assert get_resp_header(full, "accept-ranges") == ["bytes"]

    ranged =
      conn
      |> recycle()
      |> authenticated_conn(user)
      |> put_req_header("range", "bytes=0-0")
      |> get(url)

    assert response(ranged, 416) == ""
    assert get_resp_header(ranged, "content-range") == ["bytes */0"]
    refute_received {:s3_get, _path, _ranges}
  end

  test "admin full responses use bounded 64 KiB reads", %{conn: conn, user: user} do
    object = :binary.copy("a", 65_536 * 2 + 3)
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin-large.bin", object)

    conn =
      conn
      |> authenticated_conn(user)
      |> get(Presenter.attachment(attachment)["content_url"])

    assert response(conn, 200) == object
    assert_receive {:s3_get, _path, ["bytes=0-65535"]}
    assert_receive {:s3_get, _path, ["bytes=65536-131071"]}
    assert_receive {:s3_get, _path, ["bytes=131072-131074"]}
    refute_received {:s3_get, _path, []}
  end

  test "admin returns a generic 503 when the first storage read fails", %{
    conn: conn,
    user: user
  } do
    object = "admin unavailable"
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin-unavailable.txt", object)
    Application.put_env(:gsmlg_storage, :gao_note_http_admin_fail_ranges, ["bytes=0-16"])

    conn =
      conn
      |> authenticated_conn(user)
      |> get(Presenter.attachment(attachment)["content_url"])

    assert %{"errors" => %{"detail" => "Service Unavailable"}} =
             json_response(conn, 503)

    refute conn.resp_body =~ "admin upstream detail"
    assert_receive {:s3_get, _path, ["bytes=0-16"]}
  end

  test "admin aborts a partial response after a later bounded read fails", %{
    conn: conn,
    user: user
  } do
    object = :binary.copy("a", 65_536 + 10)
    note = note_fixture(user)
    attachment = attachment_fixture(note, "./admin-later-failure.bin", object)
    Application.put_env(:gsmlg_storage, :gao_note_http_admin_fail_ranges, ["bytes=65536-65545"])
    _telemetry_id = capture_log_telemetry()

    assert {:shutdown, :gao_note_attachment_storage_read_failed} =
             catch_exit(
               conn
               |> authenticated_conn(user)
               |> get(Presenter.attachment(attachment)["content_url"])
             )

    assert_receive {:s3_get, _path, ["bytes=0-65535"]}
    assert_receive {:s3_get, _path, ["bytes=65536-65545"]}

    assert_receive {:telemetry, [:gsmlg, :log], %{level: :error}, metadata}
    assert metadata.message == "Admin GaoNote attachment content stream failed"
    assert metadata.note_id == note.id
    assert metadata.path == "./admin-later-failure.bin"
    assert metadata.reason == :storage_error
    refute inspect(metadata) =~ "admin upstream detail"
  end

  test "admin note scoping returns 404 without reading another note's object", %{
    conn: conn,
    user: user
  } do
    owner_note = note_fixture(user, %{title: "Admin owner"})
    other_note = note_fixture(user, %{title: "Admin other"})
    _attachment = attachment_fixture(owner_note, "./scoped.txt", "secret")

    conn =
      conn
      |> authenticated_conn(user)
      |> get("/api/gao_notes/#{other_note.id}/attachments/scoped.txt")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(conn, 404)
    refute_received {:s3_get, _path, _ranges}
  end

  test "standalone and pathless per-note admin attachment pages do not render", %{
    conn: conn,
    user: user
  } do
    assert_error_sent 404, fn ->
      conn
      |> session_authenticated_conn(user)
      |> get("/gao_notes/attachments")
    end

    pathless =
      conn
      |> recycle()
      |> session_authenticated_conn(user)
      |> get("/gao_notes/notes/#{Ecto.UUID.generate()}/attachments")

    assert %{"errors" => %{"detail" => "Not Found"}} = json_response(pathless, 404)
  end

  defp session_authenticated_conn(conn, user) do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn
    |> with_secret_key_base()
    |> Plug.Test.init_test_session(%{})
    |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
    |> put_session(:guardian_default_token, token)
  end

  defp authenticated_conn(conn, user) do
    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp capture_log_telemetry do
    handler_id = {__MODULE__, self(), System.unique_integer([:positive, :monotonic])}

    :ok =
      :telemetry.attach(
        handler_id,
        [:gsmlg, :log],
        fn event, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp note_fixture(user, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{title: unique_id("Admin raw note"), content: "Content"},
        attrs
      )

    assert {:ok, note} = GaoNote.create_note(attrs, user)
    note
  end

  defp attachment_fixture(note, path, object, opts \\ []) do
    Application.put_env(:gsmlg_storage, :gao_note_http_admin_object, object)

    file =
      %StorageFile{}
      |> StorageFile.changeset(%{
        tenant: "gao_note",
        type: "gao_note_attachment",
        filename: Path.basename(path),
        s3_key: "gao_note/#{Ecto.UUID.generate()}",
        content_type: Keyword.get(opts, :content_type, "text/plain"),
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
        id: unique_id("admin-attachment"),
        note_id: note.id,
        storage_file_id: file.id,
        path: path,
        mime: Keyword.get(opts, :mime, "text/plain"),
        description: ""
      })
      |> Repo.insert!()

    Repo.preload(attachment, :storage_file)
  end

  defp available_port do
    {:ok, socket} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {_address, port}} = :inet.sockname(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  defp unique_id(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
