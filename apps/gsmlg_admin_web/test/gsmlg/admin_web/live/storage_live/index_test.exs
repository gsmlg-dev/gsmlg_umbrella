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
      {pid, objects} = Agent.get(state, & &1)

      case get_req_header(conn, "x-amz-copy-source") do
        [source] ->
          source_key =
            source
            |> String.trim_leading("/")
            |> String.split("/", parts: 2)
            |> List.last()
            |> URI.decode()

          {_, size} = List.keyfind(objects, source_key, 0)
          send(pid, {:s3_copy, source_key, key})

          Agent.update(state, fn {pid, current} ->
            {pid, [{key, size} | List.keydelete(current, key, 0)]}
          end)

          conn
          |> put_resp_content_type("application/xml")
          |> send_resp(
            200,
            "<CopyObjectResult><ETag>&quot;test&quot;</ETag><LastModified>2026-10-14T09:00:00Z</LastModified></CopyObjectResult>"
          )

        [] ->
          send(pid, {:s3_put, key, bytes})

          Agent.update(state, fn {pid, current} ->
            {pid, [{key, byte_size(bytes)} | List.keydelete(current, key, 0)]}
          end)

          send_resp(conn, 200, "")
      end
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
    start_supervised!({Gaoxy.HTTP, plug: {S3Stub, []}, port: port})

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

  test "exposes an accessible client-side separator between folders and files", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/storage")

    assert has_element?(view, "#storage-browser[phx-hook='StorageSplitPane']")

    assert has_element?(
             view,
             "#storage-splitter[role='separator'][aria-orientation='vertical']" <>
               "[aria-controls='storage-folder-tree'][aria-label='Resize folders panel'][tabindex='0']"
           )

    assert has_element?(view, "#storage-browser > #storage-files-panel")
    assert has_element?(view, "#storage-files-panel #storage-objects")
  end

  test "leaf action forms bind exact folder keys to the current backend without navigating", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    leaf = folder_id("gaonote/note/")
    assert eventually(fn -> has_element?(view, "##{leaf}-actions-popover-trigger") end)
    refute has_element?(view, "##{folder_id("gaonote/")}-actions-popover-trigger")

    for action <- ["rename", "delete"] do
      assert has_element?(
               view,
               "##{leaf}-#{action}-form input[name='folder[backend]'][value='#{GSMLG.Storage.Inventory.current_backend_id()}']"
             )

      assert has_element?(
               view,
               "##{leaf}-#{action}-form input[name='folder[prefix]'][value='#{GSMLG.Storage.Inventory.encode_key("gaonote/note/")}']"
             )
    end

    assert has_element?(view, "##{leaf}-delete-dialog", "all 1 files, including subfolders")

    render_click(view, "clear_folder_error", %{
      "prefix" => GSMLG.Storage.Inventory.encode_key("gaonote/note/"),
      "action" => "rename"
    })

    assert has_element?(view, "##{leaf}[aria-current='page']")
    refute_receive {:s3_copy, _, _}
    refute_receive {:s3_delete, _}
  end

  test "renames a populated leaf, refreshes the tree and follows its selected URL", %{
    conn: conn,
    s3_state: state
  } do
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    leaf = folder_id("gaonote/note/")
    assert eventually(fn -> has_element?(view, "##{leaf}-rename-form") end)

    view
    |> form("##{leaf}-rename-form", folder: %{name: "renamed"})
    |> render_submit()

    render_async(view)
    assert_receive {:s3_copy, "gaonote/note/image.png", "gaonote/renamed/image.png"}, 2_000
    assert_receive {:s3_delete, "gaonote/note/image.png"}, 2_000
    assert_patch(view, ~p"/storage?#{%{prefix: "gaonote/renamed/"}}")

    assert eventually(fn ->
             has_element?(view, "##{folder_id("gaonote/renamed/")}[aria-current='page']")
           end)

    assert has_element?(view, "#storage-objects", "gaonote/renamed/image.png")
    refute has_element?(view, "##{leaf}")

    dialog_id = leaf <> "-rename-dialog"

    assert_push_event(view, "close-dialog", %{
      id: ^dialog_id,
      focus: "#storage-root-folder"
    })

    assert {_pid, objects} = Agent.get(state, & &1)
    assert {"outside.txt", 1024} in objects
  end

  test "confirmed leaf deletion removes its marker and files and selects the parent", %{
    conn: conn,
    s3_state: state
  } do
    Agent.update(state, fn {pid, objects} ->
      {pid, [{"gaonote/note/", 0}, {"gaonote/note/second.txt", 11} | objects]}
    end)

    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    leaf = folder_id("gaonote/note/")
    assert eventually(fn -> has_element?(view, "##{leaf}-delete-form") end)
    assert has_element?(view, "##{leaf}-delete-dialog", "all 2 files")

    view |> form("##{leaf}-delete-form") |> render_submit()
    render_async(view)

    for key <- ["gaonote/note/", "gaonote/note/image.png", "gaonote/note/second.txt"] do
      assert_receive {:s3_delete, ^key}, 2_000
    end

    assert_patch(view, ~p"/storage?#{%{prefix: "gaonote/"}}")
    assert eventually(fn -> not has_element?(view, "##{leaf}") end)

    dialog_id = leaf <> "-delete-dialog"

    assert_push_event(view, "close-dialog", %{
      id: ^dialog_id,
      focus: "#storage-root-folder"
    })

    assert {_pid, [{"outside.txt", 1024}]} = Agent.get(state, & &1)
  end

  test "rename collisions stay in the dialog and leave the source unchanged", %{
    conn: conn,
    s3_state: state
  } do
    Agent.update(state, fn {pid, objects} -> {pid, [{"gaonote/taken/file.txt", 4} | objects]} end)
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    leaf = folder_id("gaonote/note/")
    assert eventually(fn -> has_element?(view, "##{leaf}-rename-form") end)

    view |> form("##{leaf}-rename-form", folder: %{name: "taken"}) |> render_submit()
    render_async(view)
    assert has_element?(view, "##{leaf}-rename-dialog [role=alert]", "already exists")
    assert has_element?(view, "##{leaf}[aria-current='page']")
    assert {_pid, objects} = Agent.get(state, & &1)
    assert {"gaonote/note/image.png", 2048} in objects
    refute_receive {:s3_copy, _, _}
    refute_receive {:s3_delete, _}
  end

  test "stale folder forms are rejected before copying or deleting objects", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    leaf = folder_id("gaonote/note/")
    assert eventually(fn -> has_element?(view, "##{leaf}-delete-form") end)
    expected = GSMLG.Storage.Inventory.current_backend_id()
    Application.put_env(:gsmlg_storage, :s3_bucket, "another-bucket")

    html =
      render_submit(view, "delete_folder", %{
        "folder" => %{
          "prefix" => GSMLG.Storage.Inventory.encode_key("gaonote/note/"),
          "backend" => expected
        }
      })

    assert html =~ "S3 configuration changed"

    dialog_id = leaf <> "-delete-dialog"

    assert_push_event(view, "close-dialog", %{
      id: ^dialog_id,
      focus: "#storage-root-folder"
    })

    refute_receive {:s3_copy, _, _}
    refute_receive {:s3_delete, _}
  end

  test "deep links expand the folder hierarchy while retaining siblings and empty folders", %{
    conn: conn,
    s3_state: state
  } do
    Agent.update(state, fn {pid, _} ->
      {pid,
       [
         {"a/deep/2026/image.txt", 10},
         {"a/sibling/note.txt", 20},
         {"z/empty/", 0}
       ]}
    end)

    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "a/deep/"}}")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "##{folder_id("a/deep/")}") end)
    assert has_element?(view, "##{folder_id("a/")}-toggle[aria-expanded='true']")
    assert has_element?(view, "##{folder_id("a/deep/")}[aria-current='page']")
    assert has_element?(view, "##{folder_id("a/deep/2026/")}")
    assert has_element?(view, "##{folder_id("a/sibling/")}")
    assert has_element?(view, "##{folder_id("z/")}")
    assert has_element?(view, "#storage-root-folder [title='Files in this bucket']", "2")
    refute has_element?(view, "#storage-folder-tree", "image.txt")

    view |> element("##{folder_id("z/")}-toggle") |> render_click()
    assert has_element?(view, "##{folder_id("z/empty/")}", "empty")
    view |> element("##{folder_id("z/empty/")}") |> render_click()
    assert_patch(view, ~p"/storage?#{%{prefix: "z/empty/"}}")
    assert has_element?(view, "##{folder_id("z/empty/")}[aria-current='page']")
    assert has_element?(view, "#storage-root-folder [title='Files in this bucket']", "2")
    assert has_element?(view, "main p", "No files in this folder")
    refute_receive {:s3_list, _}, 100
  end

  test "disclosure buttons toggle locally and directory links navigate the same snapshot", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/storage")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    toggle = "##{folder_id("gaonote/")}-toggle"
    assert eventually(fn -> has_element?(view, toggle <> "[aria-expanded='false']") end)
    refute has_element?(view, "##{folder_id("gaonote/note/")}")

    view |> element(toggle) |> render_click()
    assert has_element?(view, toggle <> "[aria-expanded='true']")
    assert has_element?(view, "##{folder_id("gaonote/note/")}")
    assert has_element?(view, "#storage-root-folder[aria-current='page']")
    assert has_element?(view, "#storage-objects", "outside.txt")

    view |> element(toggle) |> render_click()
    assert has_element?(view, toggle <> "[aria-expanded='false']")
    refute has_element?(view, "##{folder_id("gaonote/note/")}")

    view |> element("##{folder_id("gaonote/")}") |> render_click()
    assert_patch(view, ~p"/storage?#{%{prefix: "gaonote/"}}")
    assert has_element?(view, "##{folder_id("gaonote/")}[aria-current='page']")
    assert has_element?(view, "##{folder_id("gaonote/note/")}")
    assert has_element?(view, "#storage-root-folder [title='Files in this bucket']", "2")

    view |> form("#storage-search", %{search: "missing"}) |> render_submit()
    assert_patch(view, ~p"/storage?#{[prefix: "gaonote/", search: "missing"]}")
    assert has_element?(view, "##{folder_id("gaonote/note/")}")
    refute_receive {:s3_list, _}, 100
  end

  test "a late subscription snapshot cannot replace a loaded deep link", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "gaonote/note/"}}")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "image.png") end)

    initial = %{
      GSMLG.SessionProcess.StorageReducer.init_state()
      | backend_id: GSMLG.Storage.Inventory.current_backend_id()
    }

    send(view.pid, {:storage_snapshot, initial})
    assert has_element?(view, "##{folder_id("gaonote/note/")}[aria-current='page']")
    assert has_element?(view, "#storage-objects", "image.png")
    refute_receive {:s3_list, _}, 100
  end

  test "refresh updates branches, preserves expansion and forgets removed folders", %{
    conn: conn,
    s3_state: state
  } do
    Agent.update(state, fn {pid, _} -> {pid, [{"a/deep/old/file.txt", 1}]} end)
    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: "a/deep/"}}")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "##{folder_id("a/deep/old/")}") end)

    Agent.update(state, fn {pid, _} -> {pid, [{"a/new/file.txt", 2}, {"c/empty/", 0}]} end)
    view |> element("#refresh-storage") |> render_click()
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "##{folder_id("a/new/")}") end)
    refute has_element?(view, "##{folder_id("a/deep/")}")
    assert has_element?(view, "##{folder_id("c/")}")
    assert has_element?(view, "##{folder_id("a/")}-toggle[aria-expanded='true']")

    Agent.update(state, fn {pid, _} -> {pid, [{"a/deep/returned/file.txt", 3}]} end)
    view |> element("#refresh-storage") |> render_click()
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "##{folder_id("a/deep/")}-toggle") end)
    assert has_element?(view, "##{folder_id("a/deep/")}-toggle[aria-expanded='false']")
    refute has_element?(view, "##{folder_id("a/deep/returned/")}")

    view |> element("##{folder_id("a/")}-toggle") |> render_click()
    view |> element("#refresh-storage") |> render_click()
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    assert eventually(fn -> not has_element?(view, "#refresh-storage[disabled]") end)
    assert has_element?(view, "##{folder_id("a/")}-toggle[aria-expanded='false']")
  end

  test "tree navigation preserves exact prefixes containing special and empty segments", %{
    conn: conn,
    s3_state: state
  } do
    prefix = " 空格 +%&#?//中文/"
    control_prefix = "line\rbreak/"

    Agent.update(state, fn {pid, _} ->
      {pid, [{prefix <> "file.txt", 1}, {control_prefix <> "child/file.txt", 1}]}
    end)

    {:ok, view, _} = live(conn, ~p"/storage?#{%{prefix: prefix}}")
    assert_receive {:s3_list, "/current-bucket"}, 2_000
    selected = "##{folder_id(prefix)}"
    assert eventually(fn -> has_element?(view, selected <> "[aria-current='page']") end)
    assert has_element?(view, "##{folder_id(" 空格 +%&#?//")}", "/")

    assert view
           |> element(selected)
           |> render()
           |> Floki.parse_fragment!()
           |> Floki.attribute("a", "href") ==
             [~p"/storage?#{%{prefix: prefix}}"]

    assert has_element?(view, "#storage-objects", prefix <> "file.txt")
    encoded = GSMLG.Storage.Inventory.encode_key(control_prefix)
    toggle = "##{folder_id(control_prefix)}-toggle"
    assert has_element?(view, toggle <> "[phx-value-prefix='#{encoded}']")
    view |> element(toggle) |> render_click()
    assert has_element?(view, "##{folder_id(control_prefix <> "child/")}")
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
    view |> element("##{folder_id("gaonote/")}-toggle") |> render_click()
    assert has_element?(view, "##{folder_id("gaonote/note/")}")

    Agent.update(state, fn {pid, _} ->
      {pid, [{"new-bucket-only.txt", 17}, {"gaonote/replacement/file.txt", 1}]}
    end)

    assert {:ok, _config} =
             GSMLG.Storage.update_config(%{
               s3_bucket: "next-bucket",
               s3_endpoint: Application.fetch_env!(:gsmlg_storage, :s3_endpoint)
             })

    assert_receive {:s3_list, "/next-bucket"}, 2_000
    assert eventually(fn -> has_element?(view, "#storage-objects", "new-bucket-only.txt") end)
    refute has_element?(view, "#storage-objects", "outside.txt")
    refute has_element?(view, "##{folder_id("gaonote/note/")}")
    refute has_element?(view, "##{folder_id("gaonote/replacement/")}")
    assert has_element?(view, "##{folder_id("gaonote/")}-toggle[aria-expanded='false']")
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

  defp folder_id(prefix), do: "storage-folder-" <> GSMLG.Storage.Inventory.encode_key(prefix)

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
