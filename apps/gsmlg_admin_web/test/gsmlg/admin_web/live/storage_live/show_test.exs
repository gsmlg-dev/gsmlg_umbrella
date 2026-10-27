defmodule GSMLG.AdminWeb.StorageLive.ShowTest do
  use GSMLG.AdminWeb.ConnCase, async: false

  import GSMLG.AccountsFixtures

  alias GSMLG.Storage.{Inventory, StorageFile, TestCatalogClient}

  @secret_key_base String.duplicate("s", 64)

  defmodule ObjectStub do
    import Plug.Conn
    def init(opts), do: opts

    def call(%{method: "HEAD"} = conn, _opts) do
      metadata = Application.get_env(:gsmlg_storage, :show_test_s3_metadata, %{})

      conn =
        Enum.reduce(metadata, conn, fn {key, value}, conn ->
          put_resp_header(conn, "x-amz-meta-" <> key, value)
        end)

      conn
      |> put_resp_header("content-length", "2")
      |> put_resp_header("content-type", "application/json")
      |> put_resp_header("etag", "metadata-test")
      |> send_resp(200, "")
    end
  end

  setup %{conn: conn} do
    TestCatalogClient.setup!()
    keys = [:s3_endpoint, :s3_bucket, :show_test_s3_metadata]
    previous = Map.new(keys, &{&1, Application.fetch_env(:gsmlg_storage, &1)})
    endpoint_config = Application.get_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, [])

    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, {_, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    start_supervised!({Gaoxy.HTTP, plug: {ObjectStub, []}, port: port})
    Application.put_env(:gsmlg_storage, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:gsmlg_storage, :s3_bucket, "show-test")
    Application.put_env(:gsmlg_storage, :show_test_s3_metadata, %{})

    Application.put_env(
      :gsmlg_admin_web,
      GSMLG.AdminWeb.Endpoint,
      Keyword.put(endpoint_config, :secret_key_base, @secret_key_base)
    )

    on_exit(fn ->
      Application.put_env(:gsmlg_admin_web, GSMLG.AdminWeb.Endpoint, endpoint_config)

      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:gsmlg_storage, key, value)
        {key, :error} -> Application.delete_env(:gsmlg_storage, key)
      end)
    end)

    user = user_fixture()

    {:ok, token, _claims} =
      GSMLG.AdminWeb.Guardian.encode_and_sign(user, %{}, token_type: "access")

    conn =
      conn
      |> with_secret_key_base()
      |> Plug.Test.init_test_session(%{})
      |> Guardian.Plug.sign_in(GSMLG.AdminWeb.Guardian, user, %{}, token_type: "access")
      |> Plug.Conn.put_session(:guardian_default_token, token)

    %{conn: conn}
  end

  test "renders non-empty managed metadata with the JSON custom element", %{conn: conn} do
    file =
      TestCatalogClient.insert_file!(%StorageFile{
        tenant: "test",
        type: "document",
        filename: "metadata.json",
        s3_key: "test/document/metadata.json",
        content_type: "application/json",
        size: 2,
        metadata: %{"count" => 2, "nested" => %{"enabled" => true}}
      })

    html = detail_html(conn, file.s3_key)
    assert_json_element(html, file.metadata)
  end

  test "renders S3 object metadata with the JSON custom element without a managed manifest", %{
    conn: conn
  } do
    metadata = %{"source" => "external", "owner" => "storage-test"}
    Application.put_env(:gsmlg_storage, :show_test_s3_metadata, metadata)
    html = detail_html(conn, "external/metadata.json")
    assert_json_element(html, metadata)
    refute html =~ "public-url-input"
  end

  defp detail_html(conn, key) do
    encoded = Inventory.encode_key(key)
    backend = Inventory.current_backend_id()

    conn
    |> get(~p"/storage/#{encoded}?#{%{backend: backend}}")
    |> html_response(200)
  end

  defp assert_json_element(html, metadata) do
    document = Floki.parse_document!(html)

    assert [_code_block] =
             Floki.find(document, "el-dm-code-block[language='json'][copyable]")

    assert [json_element] = Floki.find(document, "el-gsmlg-json")
    assert json_element |> Floki.text() |> String.trim() == JSON.encode!(metadata)
  end

  defp with_secret_key_base(conn), do: %{conn | secret_key_base: @secret_key_base}
end
