defmodule GSMLG.AdminWeb.StorageLive.IndexTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import GSMLG.AccountsFixtures

  defmodule S3Stub do
    import Phoenix.ConnTest, only: []
    use Plug.Router
    plug(:match)
    plug(:dispatch)

    head "/*path" do
      {pid, objects} =
        Agent.get(Application.fetch_env!(:gsmlg_storage, :inventory_test_state), & &1)

      key = object_key(conn)
      send(pid, {:s3_head, conn.request_path})

      case List.keyfind(objects, key, 0) do
        {_, size} ->
          conn
          |> put_resp_header("content-length", Integer.to_string(size))
          |> put_resp_header("content-type", "image/png")
          |> put_resp_header("etag", "object-etag")
          |> put_resp_header("last-modified", "Wed, 14 Oct 2026 09:00:00 GMT")
          |> send_resp(200, "")

        nil ->
          send_resp(conn, 404, "")
      end
    end

    put "/*path" do
      {:ok, bytes, conn} = Plug.Conn.read_body(conn)
      state = Application.fetch_env!(:gsmlg_storage, :inventory_test_state)
      key = object_key(conn)
      {pid, _} = Agent.get(state, & &1)
      send(pid, {:s3_put, key, bytes})

      Agent.update(state, fn {pid, objects} ->
        {pid, [{key, byte_size(bytes)} | List.keydelete(objects, key, 0)]}
      end)

      send_resp(conn, 200, "")
    end

    delete "/*path" do
      state = Application.fetch_env!(:gsmlg_storage, :inventory_test_state)
      key = object_key(conn)
      {pid, _} = Agent.get(state, & &1)
      send(pid, {:s3_delete, key})
      Agent.update(state, fn {pid, objects} -> {pid, List.keydelete(objects, key, 0)} end)
      send_resp(conn, 204, "")
    end

    get "/*path" do
      {pid, objects} =
        Agent.get(Application.fetch_env!(:gsmlg_storage, :inventory_test_state), & &1)

      send(pid, {:s3_list, conn.request_path})

      contents =
        Enum.map_join(objects, fn {key, size} ->
          "<Contents><Key>#{URI.encode(key, &URI.char_unreserved?/1)}</Key>" <>
            "<Size>#{size}</Size><ETag>&quot;test&quot;</ETag>" <>
            "<LastModified>2026-10-14T09:00:00Z</LastModified></Contents>"
        end)

      body =
        "<ListBucketResult><EncodingType>url</EncodingType><IsTruncated>false</IsTruncated>" <>
          contents <> "</ListBucketResult>"

      conn |> put_resp_content_type("application/xml") |> send_resp(200, body)
    end

    defp object_key(conn),
      do: conn.request_path |> String.split("/", parts: 3) |> List.last() |> URI.decode()
  end

  setup %{conn: conn} do
    keys = [
      :s3_bucket,
      :s3_endpoint,
      :s3_access_key_id,
      :s3_secret_access_key,
      :inventory_test_state
    ]

    original = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])
    secret = String.duplicate("s", 64)

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, secret)
    )

    state = start_supervised!({Agent, fn -> {self(), []} end})
    test_pid = self()

    Agent.update(state, fn _ ->
      {test_pid, [{"outside.txt", 1024}, {"gaonote/note/image.png", 2048}]}
    end)

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    start_supervised!({Bandit, plug: S3Stub, port: port, startup_log: false})

    Application.put_env(:gsmlg_storage, :s3_bucket, "current-bucket")
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_access_key_id, "test-key")
    Application.put_env(:gsmlg_storage, :s3_secret_access_key, "test-secret")
    Application.put_env(:gsmlg_storage, :inventory_test_state, state)

    on_exit(fn ->
      Enum.each(original, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)

      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)
    end)

    user = user_fixture()
    {:ok, token, _} = GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      %{conn | secret_key_base: secret}
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn, s3_state: state}
  end

  test "lists actual S3 keys and refreshes external changes without a database catalog", %{
    conn: conn,
    s3_state: state
  } do
    {:ok, view, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    assert render(view) =~ "3.0 KB"

    Agent.update(state, fn {pid, _} -> {pid, [{"external-new.txt", 4096}]} end)
    view |> element("#refresh-storage") |> render_click()
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "external-new.txt") end)
    refute has_element?(view, "#storage-objects", "outside.txt")
    assert render(view) =~ "4.0 KB"
  end

  test "filters the session snapshot without rescanning S3", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)

    render_patch(view, ~p"/storage?prefix=gaonote%2Fnote%2F")
    assert has_element?(view, "#storage-objects", "image.png")
    refute_receive {:s3_list, _}, 100
  end

  test "connected mount rejects an invalid token after an authenticated HTTP render", %{
    conn: conn
  } do
    conn = get(conn, ~p"/storage")
    assert conn.status == 200

    private =
      Map.update!(conn.private, :plug_session, fn session ->
        Map.put(session, "guardian_default_token", "invalid-guardian-token")
      end)

    assert {:error, {:redirect, %{to: "/sign_in"}}} = live(%{conn | private: private})
    refute_receive {:s3_list, _}
  end

  test "refresh without an authenticated current user redirects without reading S3" do
    socket = %Phoenix.LiveView.Socket{
      endpoint: GSMLG.AdminWeb.Endpoint,
      transport_pid: self(),
      assigns: %{__changed__: %{}, flash: %{}, current_user: nil}
    }

    assert {:noreply, %{redirected: {:redirect, %{to: "/sign_in"}}}} =
             GSMLG.AdminWeb.StorageLive.Index.handle_event("refresh", %{}, socket)

    refute_receive {:s3_list, _}
  end

  test "saving another bucket discards the previous session listing", %{
    conn: conn,
    s3_state: state
  } do
    {:ok, view, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    Agent.update(state, fn {pid, _} -> {pid, [{"new-bucket-only.txt", 17}]} end)

    assert {:ok, _config} =
             GSMLG.Storage.update_config(%{
               s3_bucket: "next-bucket",
               s3_endpoint: Application.fetch_env!(:gsmlg_storage, :s3_endpoint)
             })

    assert_receive {:s3_list, "/next-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "new-bucket-only.txt") end)
    refute has_element?(view, "#storage-objects", "outside.txt")
    assert render(view) =~ "next-bucket"
  end

  test "invalid changed configuration clears old objects and shows a refresh error", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    Application.put_env(:gsmlg_storage, :s3_endpoint, "not-an-s3-url")
    Phoenix.PubSub.broadcast(GSMLG.PubSub, "storage:config", {:storage_backend_changed, :invalid})

    assert eventually(fn -> has_element?(view, "#storage-error") end)
    refute has_element?(view, "#storage-objects", "outside.txt")
    refute_receive {:s3_list, _}
  end

  test "another authenticated session reads a fresh listing", %{conn: conn, s3_state: state} do
    {:ok, first, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(first, "#storage-objects", "outside.txt") end)
    Agent.update(state, fn {pid, _} -> {pid, [{"another-session.txt", 11}]} end)

    other_conn =
      Plug.Conn.put_session(
        conn,
        :session_id,
        Phoenix.SessionProcess.SessionId.generate_unique_session_id()
      )

    {:ok, second, _html} = live(other_conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(second, "#storage-objects", "another-session.txt") end)
    assert has_element?(first, "#storage-objects", "outside.txt")
    refute has_element?(first, "#storage-objects", "another-session.txt")
  end

  test "listing and refresh never query database file metadata", %{conn: conn} do
    id = "storage-index-no-catalog-#{System.unique_integer([:positive])}"
    event = GSMLG.Repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _event, _measurements, metadata, pid ->
          if String.contains?(metadata.query, ["storage_files", "storage_folders"]) do
            send(pid, {:database_file_metadata, metadata.query})
          end
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)
    {:ok, view, _html} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    view |> element("#refresh-storage") |> render_click()
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> not has_element?(view, "#refresh-storage[disabled]") end)
    refute_receive {:database_file_metadata, _query}
  end

  test "details follow exact encoded S3 keys and show HEAD metadata without exposing a raw download",
       %{conn: conn, s3_state: state} do
    key = "folder/a b+雪.png"
    Agent.update(state, fn {pid, _} -> {pid, [{key, 13}]} end)
    backend = GSMLG.Storage.Inventory.current_backend_id()
    encoded = GSMLG.Storage.Inventory.encode_key(key)
    {:ok, index, _} = live(conn, ~p"/storage?prefix=folder%2F")
    assert eventually(fn -> has_element?(index, "#storage-objects", key) end)
    assert has_element?(index, "a[href='/storage/#{encoded}?backend=#{backend}']")

    {:ok, show, html} = live(conn, ~p"/storage/#{encoded}?#{%{backend: backend}}")
    assert html =~ key
    assert html =~ "13 B"
    assert html =~ "object-etag"
    refute has_element?(show, "#public-url-input")
    refute has_element?(show, "img")
    assert_receive {:s3_head, path}
    assert URI.decode(path) == "/current-bucket/#{key}"
  end

  test "managed details keep the existing UUID preview route", %{conn: conn, s3_state: state} do
    GSMLG.Storage.TestCatalogClient.setup!()
    key = "managed/image.png"
    Agent.update(state, fn {pid, _} -> {pid, [{key, 20}]} end)

    file =
      GSMLG.Storage.TestCatalogClient.insert_file!(%GSMLG.Storage.StorageFile{
        tenant: "managed",
        type: "image",
        filename: "image.png",
        s3_key: key,
        content_type: "image/png",
        size: 20,
        status: "active"
      })

    backend = GSMLG.Storage.Inventory.current_backend_id()
    encoded = GSMLG.Storage.Inventory.encode_key(key)
    {:ok, show, _} = live(conn, ~p"/storage/#{encoded}?#{%{backend: backend}}")
    assert has_element?(show, "img[src='/files/#{file.id}']")
    assert has_element?(show, "#public-url-input[value='/files/#{file.id}']")
  end

  test "detail deletion uses the loaded exact key and returns to a fresh listing", %{conn: conn} do
    backend = GSMLG.Storage.Inventory.current_backend_id()
    encoded = GSMLG.Storage.Inventory.encode_key("outside.txt")
    {:ok, show, _} = live(conn, ~p"/storage/#{encoded}?#{%{backend: backend}}")
    render_click(show, "delete", %{"backend" => backend})
    assert_receive {:s3_delete, "outside.txt"}
    assert_redirect(show, ~p"/storage")
  end

  test "details reject a stale backend before reading any S3 object", %{conn: conn} do
    old = GSMLG.Storage.Inventory.current_backend_id()
    Application.put_env(:gsmlg_storage, :s3_bucket, "replacement-bucket")
    key = GSMLG.Storage.Inventory.encode_key("outside.txt")

    assert {:error, {:live_redirect, %{to: "/storage"}}} =
             live(conn, ~p"/storage/#{key}?#{%{backend: old}}")

    refute_receive {:s3_head, _}
    refute_receive {:s3_list, _}
  end

  test "internal manifests and invalid detail keys are rejected before S3 access", %{conn: conn} do
    backend = GSMLG.Storage.Inventory.current_backend_id()

    for key <- [".gsmlg-storage/objects/private.json", <<255>>] do
      encoded = GSMLG.Storage.Inventory.encode_key(key)

      assert {:error, {:live_redirect, %{to: "/storage"}}} =
               live(conn, ~p"/storage/#{encoded}?#{%{backend: backend}}")
    end

    refute_receive {:s3_head, _}
    refute_receive {:s3_list, _}
  end

  test "creates a folder marker and deletes an external object then refreshes the snapshot", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/storage")
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    backend = GSMLG.Storage.Inventory.current_backend_id()
    view |> form("#create-storage-folder", %{folder: "new", backend: backend}) |> render_submit()
    assert_receive {:s3_put, "new/", ""}
    assert eventually(fn -> has_element?(view, "nav", "new") end)

    render_click(view, "delete", %{
      "key" => GSMLG.Storage.Inventory.encode_key("outside.txt"),
      "backend" => backend
    })

    assert_receive {:s3_delete, "outside.txt"}
    assert eventually(fn -> not has_element?(view, "#storage-objects", "outside.txt") end)
  end

  test "stale mutation requests reject bucket changes without writing or deleting", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/storage")
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    backend = GSMLG.Storage.Inventory.current_backend_id()
    Application.put_env(:gsmlg_storage, :s3_bucket, "replacement-bucket")

    render_click(view, "delete", %{
      "key" => GSMLG.Storage.Inventory.encode_key("outside.txt"),
      "backend" => backend
    })

    render_submit(view, "create_folder", %{"folder" => "new", "backend" => backend})
    assert render(view) =~ "S3 configuration changed"
    refute_receive {:s3_delete, _}
    refute_receive {:s3_put, _, _}
  end

  test "uploads retain the client filename and publish a managed S3 identity", %{conn: conn} do
    GSMLG.Storage.TestCatalogClient.setup!()
    {:ok, view, _} = live(conn, ~p"/storage")
    assert eventually(fn -> has_element?(view, "#storage-objects", "outside.txt") end)
    view |> element("#toggle-storage-upload") |> render_click()

    upload =
      file_input(view, "#storage-upload-form", :files, [
        %{name: "client-note.txt", content: "client bytes", type: "text/plain"}
      ])

    assert render_upload(upload, "client-note.txt") =~ "100%"
    backend = GSMLG.Storage.Inventory.current_backend_id()

    view
    |> form("#storage-upload-form", %{tenant: "admin", type: "document", backend: backend})
    |> render_submit()

    assert_receive {:s3_put, key, "client bytes"}
    assert key =~ "admin/document/"

    assert [%{filename: "client-note.txt", s3_key: ^key, status: "active"}] =
             GSMLG.Storage.TestCatalogClient.files()

    assert eventually(fn -> has_element?(view, "nav", "admin") end)

    render_patch(
      view,
      ~p"/storage?#{%{prefix: GSMLG.AdminWeb.StorageLive.Helpers.parent_prefix(key)}}"
    )

    assert has_element?(view, "#storage-objects", key)
  end

  test "mutation and detail events without an authenticated user do not access S3" do
    socket = %Phoenix.LiveView.Socket{
      endpoint: GSMLG.AdminWeb.Endpoint,
      transport_pid: self(),
      assigns: %{__changed__: %{}, flash: %{}, current_user: nil}
    }

    for module <- [GSMLG.AdminWeb.StorageLive.Index, GSMLG.AdminWeb.StorageLive.Show] do
      assert {:noreply, %{redirected: {:redirect, %{to: "/sign_in"}}}} =
               module.handle_event("delete", %{}, socket)
    end

    refute_receive {:s3_delete, _}
    refute_receive {:s3_head, _}
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
